import AppIntents
import SwiftData

/// "添加待办": saved straight away, no AI. Time words in the title ("明天下午三点") set the due time.
struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "添加待办"
    static let description = IntentDescription("直接添加一条待办。说了时间（比如「明天下午三点交报告」）会设为截止时间并按时提醒。")

    @Parameter(title: "待办事项", requestValueDialog: "要添加什么待办？")
    var title: String

    @Parameter(title: "截止时间")
    var due: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("添加待办「\(\.$title)」") {
            \.$due
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = FillerCleaner.clean(title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw $title.needsValueError("要添加什么待办？") }
        var dueDate = due
        var hasTime = due != nil
        if dueDate == nil, let spoken = SpokenDate.resolve(name, now: .now) {
            dueDate = spoken.date
            hasTime = spoken.hasTime
        }
        let context = AppSchema.shared.mainContext
        context.insert(TaskItem(title: name, dueDate: dueDate, hasDueTime: hasTime))
        try context.save()
        _ = await NotificationScheduler.shared.reschedule()

        let when = dueDate.map { date in
            hasTime ? date.formatted(.dateTime.month().day().hour().minute()) : date.formatted(.dateTime.month().day())
        }
        return .result(dialog: IntentDialog(stringLiteral: when.map { String(localized: "已添加待办「\(name)」，\($0)") }
                                            ?? String(localized: "已添加待办「\(name)」")))
    }
}

/// "这个月花了多少": the total, and how much of the budget is left.
struct SpendingIntent: AppIntent {
    static let title: LocalizedStringResource = "查询支出"
    static let description = IntentDescription("说出一段时间里花了多少，可以只看某个分类；查本月时顺便告诉你预算还剩多少。")

    @Parameter(title: "时间范围", default: .thisMonth)
    var period: SpendingPeriod

    @Parameter(title: "分类")
    var category: CategoryEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("查询\(\.$period)的支出") {
            \.$category
        }
    }

    /// Amounts aren't read out from a locked phone.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let context = AppSchema.shared.mainContext
        let summaryPeriod = period.summaryPeriod
        let total = LedgerSummary.expenses(in: LedgerSummary.interval(summaryPeriod), categoryName: category?.name, context: context)
        let currency = LedgerSummary.baseCurrency
        var sentence = category.map { String(localized: "\(summaryPeriod.title)「\($0.name)」支出 \(total.money(currency))") }
            ?? String(localized: "\(summaryPeriod.title)支出 \(total.money(currency))")
        if summaryPeriod == .thisMonth, let budget = LedgerSummary.monthlyBudget(categoryName: category?.name, context: context), budget > 0 {
            let left = budget - total
            sentence += left >= 0
                ? String(localized: "，预算还剩 \(left.money(currency))")
                : String(localized: "，已超出预算 \((-left).money(currency))")
        }
        let spoken = String(localized: "\(sentence)。")
        return .result(value: NSDecimalNumber(decimal: total).doubleValue, dialog: IntentDialog(stringLiteral: spoken))
    }
}

enum SpendingPeriod: String, AppEnum {
    case today, thisWeek, thisMonth, lastMonth, thisYear

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "时间范围"
    static let caseDisplayRepresentations: [SpendingPeriod: DisplayRepresentation] = [
        .today: "今天", .thisWeek: "本周", .thisMonth: "本月", .lastMonth: "上个月", .thisYear: "今年",
    ]

    var summaryPeriod: LedgerSummary.Period {
        LedgerSummary.Period(rawValue: rawValue) ?? .thisMonth
    }
}

/// An expense category, by name: what Siri hears and what stays stable across launches.
struct CategoryEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "分类"
    static let defaultQuery = CategoryQuery()

    var id: String { name }
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct CategoryQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [CategoryEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [CategoryEntity] {
        try await suggestedEntities().filter { $0.name.localizedCaseInsensitiveContains(string) || string.contains($0.name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [CategoryEntity] {
        let expense = CategoryKind.expense.rawValue
        let descriptor = FetchDescriptor<LedgerCategory>(predicate: #Predicate { $0.kindRaw == expense },
                                                         sortBy: [SortDescriptor(\.sortOrder)])
        let categories = try AppSchema.shared.mainContext.fetch(descriptor)
        var seen = Set<String>()
        return categories.compactMap { seen.insert($0.name).inserted ? CategoryEntity(name: $0.name) : nil }
    }
}

/// "问随口记": a question about the person's records, answered aloud. Numbers are counted on the
/// phone; AI only reads questions the rules can't.
struct AskQuestionIntent: AppIntent {
    static let title: LocalizedStringResource = "问随口记"
    static let description = IntentDescription("问花了多少、钱花在哪、还有什么待办、什么快到期，或者笔记里写过的事。")
    /// Amounts and notes aren't read out from a locked phone.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "问题", requestValueDialog: "想问什么？")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        do {
            let answer = try await AskEngine.ask(question, context: AppSchema.shared.mainContext)
            AskHistory.append(AskRecord(date: .now, question: question, answer: answer, currency: LedgerSummary.baseCurrency))
            var spoken = answer.headline
            if let first = answer.details.first { spoken += String(localized: "\(first)。") }
            if answer.headline.hasSuffix("：") {
                spoken += answer.items.prefix(3).map(\.title).joined(separator: "；")
            } else if !answer.items.isEmpty, [.tasks, .bills, .expiries].contains(answer.plan?.subject) {
                spoken += answer.items.prefix(5).map(\.title).joined(separator: "、") + "。"
            }
            return .result(value: spoken, dialog: IntentDialog(stringLiteral: spoken))
        } catch AIError.needsConsent {
            let text = String(localized: "这个问题需要用云端 AI，请先在随口记里问一次并同意发送。")
            return .result(value: text, dialog: IntentDialog(stringLiteral: text))
        }
    }
}

/// Opens the weekly or monthly report.
struct OpenReportIntent: AppIntent {
    static let title: LocalizedStringResource = "看周报或月报"
    static let description = IntentDescription("打开随口记的周报或月报。")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "报告", default: .week)
    var kind: ReportKindEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.openReport(kind == .month ? .month : .week)
        return .result()
    }
}

enum ReportKindEntity: String, AppEnum {
    case week, month

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "报告"
    static let caseDisplayRepresentations: [ReportKindEntity: DisplayRepresentation] = [.week: "周报", .month: "月报"]
}

/// Phrases Siri knows without any setup, and the actions listed in Shortcuts and Spotlight.
struct RambleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CaptureIntent(), phrases: [
            "用\(.applicationName)记一笔",
            "\(.applicationName)记一笔",
            "在\(.applicationName)记一下",
        ], shortTitle: "记一笔", systemImageName: "mic")
        AppShortcut(intent: AddTaskIntent(), phrases: [
            "在\(.applicationName)添加待办",
            "用\(.applicationName)加个待办",
        ], shortTitle: "添加待办", systemImageName: "checkmark.circle")
        AppShortcut(intent: SpendingIntent(), phrases: [
            "\(.applicationName)这个月花了多少",
            "用\(.applicationName)查\(\.$period)支出",
            "\(.applicationName)\(\.$period)花了多少",
        ], shortTitle: "查询支出", systemImageName: "yensign.circle")
        AppShortcut(intent: AskQuestionIntent(), phrases: [
            "问\(.applicationName)",
            "问问\(.applicationName)",
            "用\(.applicationName)查一下",
        ], shortTitle: "问一问", systemImageName: "bubble.left.and.text.bubble.right")
        AppShortcut(intent: OpenReportIntent(), phrases: [
            "看\(.applicationName)\(\.$kind)",
            "打开\(.applicationName)\(\.$kind)",
        ], shortTitle: "周报 / 月报", systemImageName: "chart.bar.xaxis")
    }

    static let shortcutTileColor: ShortcutTileColor = .blue
}
