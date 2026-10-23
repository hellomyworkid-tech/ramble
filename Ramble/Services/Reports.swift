import FoundationModels
import Foundation
import SwiftData

/// A week or a month at a glance: where the money went against the period before, what got
/// done, and what's coming up. Every figure is counted on the phone.
nonisolated struct PeriodReport: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case week, month
        var id: String { rawValue }
        var title: String { self == .week ? String(localized: "周报") : String(localized: "月报") }
    }

    struct CategoryLine: Equatable, Identifiable {
        var id: String { name }
        var name: String
        var colorHex: String
        var symbol: String
        var amount: Decimal
        var previous: Decimal
        var share: Double
    }

    struct EntryLine: Equatable, Identifiable {
        var id: String
        var title: String
        var category: String
        var amount: Decimal
        var date: Date
    }

    struct UpcomingLine: Equatable, Identifiable {
        var id: String
        var name: String
        var date: Date
        var amount: Decimal?
        var currency: String
    }

    var kind: Kind
    var period: QueryPeriod
    var previousPeriod: QueryPeriod
    /// Still running: today falls inside it.
    var isCurrent: Bool
    var currency: String

    var expense: Decimal = 0
    var income: Decimal = 0
    var expenseCount = 0
    var previousExpense: Decimal = 0
    var previousIncome: Decimal = 0
    var dailyAverage: Decimal = 0
    var categories: [CategoryLine] = []
    var biggest: [EntryLine] = []
    var budget: Decimal?
    var overBudget: [String] = []

    var tasksCompleted = 0
    var tasksAdded = 0
    var overdueOpen = 0
    var upcomingBills: [UpcomingLine] = []
    var upcomingExpiries: [UpcomingLine] = []

    var noteEntries = 0
    var keyPoints = 0
    var busiestNotes: [String] = []

    /// Plain-language observations, most important first.
    var highlights: [String] = []

    var hasMoney: Bool { expense > 0 || income > 0 }

    /// Name of the period before, for comparisons.
    var previousLabel: String {
        kind == .week ? String(localized: "前一周") + (isCurrent ? String(localized: "同期") : "") : previousPeriod.label
    }

    /// The figures handed to AI for its comment: totals and category names only, no notes.
    var aiSummaryInput: String {
        var lines = [
            "\(kind == .week ? "周报" : "月报")：\(period.label)\(isCurrent ? "（进行中）" : "")",
            "支出 \(expense.money(currency))，\(expenseCount) 笔；\(previousLabel)支出 \(previousExpense.money(currency))",
            "收入 \(income.money(currency))；\(previousLabel)收入 \(previousIncome.money(currency))",
            "日均支出 \(dailyAverage.money(currency))",
        ]
        if let budget { lines.append("每月预算 \(budget.money(currency))") }
        lines.append("分类：" + categories.prefix(8).map { "\($0.name) \($0.amount.money(currency))（\(previousLabel) \($0.previous.money(currency))）" }.joined(separator: "；"))
        if !biggest.isEmpty {
            lines.append("最大几笔：" + biggest.prefix(3).map { "\($0.category) \($0.amount.money(currency))" }.joined(separator: "；"))
        }
        lines.append("完成待办 \(tasksCompleted) 件，新增 \(tasksAdded) 件，已过期未完成 \(overdueOpen) 件")
        if !upcomingBills.isEmpty {
            lines.append("接下来的账单：" + upcomingBills.map { "\($0.name) \($0.amount?.money($0.currency) ?? "")" }.joined(separator: "；"))
        }
        lines.append("记笔记 \(noteEntries) 条，重点 \(keyPoints) 条")
        return lines.joined(separator: "\n")
    }
}

/// Whether the weekly and monthly reports announce themselves.
nonisolated enum ReportSettings {
    static let weeklyKey = "reports.weeklyReminder"
    static let monthlyKey = "reports.monthlyReminder"

    static var weeklyReminder: Bool { UserDefaults.standard.object(forKey: weeklyKey) as? Bool ?? true }
    static var monthlyReminder: Bool { UserDefaults.standard.object(forKey: monthlyKey) as? Bool ?? true }
}

enum ReportBuilder {
    /// The report to open by default: the one just finished, unless the current one is well under way.
    static func defaultPeriod(_ kind: PeriodReport.Kind, now: Date = .now) -> QueryPeriod {
        let calendar = PeriodResolver.calendar
        let current = period(kind, containing: now, now: now)
        let elapsed = calendar.dateComponents([.day], from: current.start, to: now).day ?? 0
        let minimum = kind == .week ? 3 : 7
        return elapsed >= minimum ? current : period(kind, containing: calendar.date(byAdding: .day, value: -1, to: current.start)!, now: now)
    }

    static func period(_ kind: PeriodReport.Kind, containing date: Date, now: Date = .now) -> QueryPeriod {
        let calendar = PeriodResolver.calendar
        switch kind {
        case .week:
            let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)!.start
            let start = calendar.dateInterval(of: .weekOfYear, for: date)!.start
            let label: String? = start == thisWeek ? String(localized: "本周")
                : start == calendar.date(byAdding: .day, value: -7, to: thisWeek) ? String(localized: "上周") : nil
            return PeriodResolver.week(containing: date, label: label)
        case .month:
            let sameMonth = calendar.isDate(date, equalTo: now, toGranularity: .month)
            return PeriodResolver.month(containing: date, now: now, label: sameMonth ? String(localized: "本月") : nil)
        }
    }

    static func shifted(_ period: QueryPeriod, kind: PeriodReport.Kind, by steps: Int, now: Date = .now) -> QueryPeriod {
        let calendar = PeriodResolver.calendar
        let date = kind == .week
            ? calendar.date(byAdding: .day, value: 7 * steps, to: period.start)!
            : calendar.date(byAdding: .month, value: steps, to: period.start)!
        return self.period(kind, containing: date, now: now)
    }

    static func make(_ kind: PeriodReport.Kind, period: QueryPeriod, context: ModelContext, now: Date = .now) -> PeriodReport {
        let calendar = PeriodResolver.calendar
        // A report still running is compared with the same days of the one before.
        let previous = PeriodResolver.samePoint(in: shifted(period, kind: kind, by: -1, now: now), for: period, now: now)
        var report = PeriodReport(kind: kind, period: period, previousPeriod: previous, isCurrent: period.holds(now),
                                  currency: LedgerSummary.baseCurrency)

        // Money.
        func fetch(_ p: QueryPeriod) -> [LedgerEntry] {
            let start = p.start, end = p.end
            return (try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.date >= start && $0.date < end }))) ?? []
        }
        let entries = fetch(period)
        let before = fetch(previous)
        let expenses = entries.filter { $0.kind == .expense }
        let previousExpenses = before.filter { $0.kind == .expense }
        report.expense = expenses.reduce(0) { $0 + $1.baseAmount }
        report.income = entries.filter { $0.kind == .income }.reduce(0) { $0 + $1.baseAmount }
        report.expenseCount = expenses.count
        report.previousExpense = previousExpenses.reduce(0) { $0 + $1.baseAmount }
        report.previousIncome = before.filter { $0.kind == .income }.reduce(0) { $0 + $1.baseAmount }
        let elapsedEnd = report.isCurrent ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))! : period.end
        let days = max(1, calendar.dateComponents([.day], from: period.start, to: elapsedEnd).day ?? 1)
        report.dailyAverage = report.expense / Decimal(days)

        func top(_ entry: LedgerEntry) -> LedgerCategory? { entry.category?.parent ?? entry.category }
        var lines: [String: PeriodReport.CategoryLine] = [:]
        for entry in expenses {
            let category = top(entry)
            let name = category?.name ?? String(localized: "未分类")
            lines[name, default: .init(name: name, colorHex: category?.colorHex ?? "#8E8E93", symbol: category?.symbol ?? "tag",
                                       amount: 0, previous: 0, share: 0)].amount += entry.baseAmount
        }
        for entry in previousExpenses {
            let category = top(entry)
            let name = category?.name ?? String(localized: "未分类")
            lines[name, default: .init(name: name, colorHex: category?.colorHex ?? "#8E8E93", symbol: category?.symbol ?? "tag",
                                       amount: 0, previous: 0, share: 0)].previous += entry.baseAmount
        }
        report.categories = lines.values
            .map { line in
                var line = line
                line.share = report.expense > 0 ? NSDecimalNumber(decimal: line.amount / report.expense).doubleValue : 0
                return line
            }
            .sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.previous > $1.previous }
        report.biggest = expenses.sorted { $0.baseAmount > $1.baseAmount }.prefix(3).map {
            .init(id: ModelRef.encode($0.persistentModelID), title: $0.displayTitle, category: top($0)?.name ?? String(localized: "未分类"),
                  amount: $0.baseAmount, date: $0.date)
        }

        if kind == .month {
            let budgets = (try? context.fetch(FetchDescriptor<Budget>())) ?? []
            report.budget = budgets.first { $0.category == nil }?.amount
            report.overBudget = budgets.compactMap { budget in
                guard let name = budget.category?.name, budget.amount > 0,
                      let spent = report.categories.first(where: { $0.name == name })?.amount, spent > budget.amount else { return nil }
                return name
            }
        }

        // To-dos.
        let tasks = (try? context.fetch(FetchDescriptor<TaskItem>())) ?? []
        report.tasksCompleted = tasks.filter { $0.isCompleted && period.holds($0.completedAt ?? .distantPast) }.count
        report.tasksAdded = tasks.filter { period.holds($0.createdAt) }.count
        report.overdueOpen = tasks.filter { $0.isOverdue(now: now, calendar: calendar) }.count

        // What's next: the following period.
        let next = shifted(period, kind: kind, by: 1, now: now)
        let horizonStart = max(calendar.startOfDay(for: now), next.start)
        let horizonEnd = report.isCurrent ? next.end : max(next.end, calendar.date(byAdding: .day, value: 14, to: calendar.startOfDay(for: now))!)
        let bills = (try? context.fetch(FetchDescriptor<Bill>(predicate: #Predicate { $0.isActive }, sortBy: [SortDescriptor(\.nextDueDate)]))) ?? []
        report.upcomingBills = bills.filter { $0.nextDueDate >= min(horizonStart, calendar.startOfDay(for: now)) && $0.nextDueDate < horizonEnd }
            .prefix(5).map { .init(id: ModelRef.encode($0.persistentModelID), name: $0.name, date: $0.nextDueDate, amount: $0.amount, currency: $0.currencyCode) }
        let expiryEnd = calendar.date(byAdding: .day, value: 60, to: calendar.startOfDay(for: now))!
        let expiries = (try? context.fetch(FetchDescriptor<ExpiryItem>(predicate: #Predicate { !$0.isArchived }, sortBy: [SortDescriptor(\.expiryDate)]))) ?? []
        report.upcomingExpiries = expiries.filter { $0.expiryDate >= calendar.startOfDay(for: now) && $0.expiryDate < expiryEnd }
            .prefix(3).map { .init(id: ModelRef.encode($0.persistentModelID), name: $0.name, date: $0.expiryDate, amount: nil, currency: "") }

        // Notes.
        let start = period.start, end = period.end
        let noteEntries = (try? context.fetch(FetchDescriptor<NoteEntry>(predicate: #Predicate { $0.date >= start && $0.date < end }))) ?? []
        report.noteEntries = noteEntries.count
        report.keyPoints = noteEntries.filter(\.isImportant).count
        let counts = Dictionary(grouping: noteEntries.compactMap { $0.note?.displayTitle }, by: { $0 }).mapValues(\.count)
        report.busiestNotes = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3).map(\.key)

        report.highlights = highlights(report, now: now)
        return report
    }

    /// The few things worth saying about the period, in order of importance.
    static func highlights(_ report: PeriodReport, now: Date) -> [String] {
        var notes: [String] = []
        let currency = report.currency
        func money(_ value: Decimal) -> String { value.money(currency) }

        if report.expense > 0 {
            if let change = QueryRunner.changeSentence(report.expense, against: report.previousExpense, label: report.previousLabel) {
                notes.append(String(localized: "支出\(change)"))
            }
            // Categories that grew a lot, or appeared from nothing.
            let threshold = max(Decimal(100), report.expense / 10)
            for line in report.categories {
                let diff = line.amount - line.previous
                if line.previous > 0, diff >= threshold, diff / line.previous >= Decimal(0.3) {
                    let pct = NSDecimalNumber(decimal: diff / line.previous).doubleValue.formatted(.percent.precision(.fractionLength(0)))
                    notes.append(String(localized: "\(line.name)比\(report.previousLabel)多 \(money(diff))（+\(pct)），值得留意"))
                } else if line.previous == 0, report.previousExpense > 0, line.amount >= threshold, line.share >= 0.15 {
                    notes.append(String(localized: "新出现一笔大项：\(line.name) \(money(line.amount))"))
                }
                if notes.count >= 3 { break }
            }
            // Unless its category was just mentioned.
            if let first = report.biggest.first, report.expense > 0, !notes.contains(where: { $0.contains(first.category) }),
               NSDecimalNumber(decimal: first.amount / report.expense).doubleValue >= 0.25 {
                let share = NSDecimalNumber(decimal: first.amount / report.expense).doubleValue.formatted(.percent.precision(.fractionLength(0)))
                notes.append(String(localized: "最大一笔「\(first.title)」\(money(first.amount))，占\(share)"))
            }
        }
        if let budget = report.budget, budget > 0, report.kind == .month {
            let used = NSDecimalNumber(decimal: report.expense / budget).doubleValue
            if used >= 1 {
                notes.append(String(localized: "已超出月预算 \(money(report.expense - budget))"))
            } else if report.isCurrent, used >= 0.8 {
                let calendar = PeriodResolver.calendar
                let daysLeft = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: report.period.end).day ?? 0
                notes.append(String(localized: "预算已用 \(used.formatted(.percent.precision(.fractionLength(0))))，还剩 \(money(budget - report.expense))，本月还有 \(daysLeft) 天"))
            }
        }
        if !report.overBudget.isEmpty {
            notes.append(String(localized: "超出分类预算：\(report.overBudget.joined(separator: "、"))"))
        }
        if report.tasksCompleted > 0 || report.overdueOpen > 0 {
            var line = String(localized: "完成了 \(report.tasksCompleted) 件待办")
            if report.overdueOpen > 0 { line += String(localized: "，还有 \(report.overdueOpen) 件已过期") }
            notes.append(line)
        }
        if let bill = report.upcomingBills.first {
            let more = report.upcomingBills.count > 1 ? String(localized: "等 \(report.upcomingBills.count) 笔") : ""
            notes.append(String(localized: "接下来要付：\(bill.name) \(bill.amount?.money(bill.currency) ?? "")（\(bill.date.formatted(.dateTime.month().day()))）\(more)"))
        }
        if !report.hasMoney && report.tasksCompleted == 0 && report.noteEntries == 0 {
            notes.append(String(localized: "这段时间还没有记录。"))
        }
        return notes
    }
}

/// AI's short comment on a report, from the totals alone.
nonisolated struct ReportComment: Codable, Equatable {
    var summary = ""
    var suggestions: [String] = []

    init(summary: String = "", suggestions: [String] = []) {
        self.summary = summary
        self.suggestions = suggestions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? ""
        suggestions = (try? c.decodeIfPresent([String].self, forKey: .suggestions)) ?? []
    }

    static let schema: SchemaNode = .object([
        .init("summary", .string(description: "Two or three sentences on how the period went, using the figures given, in the language the instructions name.")),
        .init("suggestions", .array(.string(description: "One short, concrete suggestion, in the same language."),
                                    description: "At most two suggestions; empty if none are worth making.")),
    ])

    /// In the language the app is shown in; the figures are labelled in Chinese either way.
    static var instructions: String {
        """
        You write a short, friendly comment on someone's weekly or monthly summary from their personal organizer. \
        Use only the figures given; never invent amounts. Note what changed most and anything that needs attention \
        (a category that grew a lot, a budget running out, overdue to-dos, bills coming up). Write in plain \(AppLanguage.name), \
        no lists in the summary, no moralising. Suggestions must be specific and doable.
        """
    }

    /// Kept per period so reopening a report doesn't ask again; dropped when the figures change.
    static func cached(for report: PeriodReport) -> ReportComment? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(report)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.fingerprint == fingerprint(report) else { return nil }
        return stored.comment
    }

    static func store(_ comment: ReportComment, for report: PeriodReport) {
        let data = try? JSONEncoder().encode(Stored(fingerprint: fingerprint(report), comment: comment))
        UserDefaults.standard.set(data, forKey: cacheKey(report))
    }

    private struct Stored: Codable {
        var fingerprint: String
        var comment: ReportComment
    }

    private static func cacheKey(_ report: PeriodReport) -> String {
        "report.comment.\(report.kind.rawValue).\(Int(report.period.start.timeIntervalSince1970))"
    }

    private static func fingerprint(_ report: PeriodReport) -> String {
        "\(report.expense)|\(report.income)|\(report.expenseCount)|\(report.tasksCompleted)|\(report.noteEntries)"
    }
}

@Generable
nonisolated struct OnDeviceReportComment {
    @Guide(description: "Two or three sentences on how the period went, using the figures given, in the language the instructions name.")
    var summary: String
    @Guide(description: "At most two short, concrete suggestions, in the same language.")
    var suggestions: [String]
}

enum ReportCommentator {
    static func comment(on report: PeriodReport) async throws -> (ReportComment, CaptureSource) {
        let input = report.aiSummaryInput
        return try await AIRouter.run(
            onDevice: {
                let session = LocalAI.makeSession(instructions: ReportComment.instructions)
                let response = try await session.respond(to: input, generating: OnDeviceReportComment.self,
                                                         options: LocalAI.options(maximumTokens: 320))
                return ReportComment(summary: response.content.summary, suggestions: Array(response.content.suggestions.prefix(2)))
            },
            isUsable: { !$0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            isEmpty: { $0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            cloud: { client in
                var client = client
                client.thinking = .fast
                var comment = try await client.generate(ReportComment.self, instructions: ReportComment.instructions,
                                                        input: input, schema: ReportComment.schema)
                comment.suggestions = Array(comment.suggestions.prefix(2))
                return comment
            })
    }
}
