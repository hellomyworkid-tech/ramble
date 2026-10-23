import AppIntents
import Foundation

// Compiled into both the app and the widget extension.

/// What the widgets show, written by the app whenever its data changes. Widgets can't open the
/// app's database, so they read this small summary from the shared app-group folder instead.
nonisolated struct WidgetSnapshot: Codable, Equatable {
    struct Task: Codable, Equatable, Identifiable {
        /// The task's record reference, for completing it from the widget.
        var id: String
        var title: String
        var due: Date?
        var hasDueTime: Bool
        /// 0 none … 3 high.
        var priority: Int
    }

    struct Upcoming: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case bill, expiry }
        var id: String
        var kind: Kind
        var name: String
        var date: Date
        var amount: Decimal?
        var currency: String
        var symbol: String
    }

    var generatedAt: Date
    var currency: String
    /// Open tasks due by the end of tomorrow, soonest first: tomorrow's are there so the widget
    /// is right after midnight before the app has run again.
    var tasks: [Task]
    var monthStart: Date
    var monthExpense: Decimal
    var monthIncome: Decimal
    var monthBudget: Decimal?
    var todayExpense: Decimal
    /// Bills and expiry dates coming up, soonest first.
    var upcoming: [Upcoming]

    /// What the widget gallery shows, in the phone's language and currency.
    static var placeholder: WidgetSnapshot {
        let currency = Locale.current.currency?.identifier ?? "CNY"
        return WidgetSnapshot(
        generatedAt: .now, currency: currency,
        tasks: [
            Task(id: "1", title: String(localized: "交季度报告"), due: .now, hasDueTime: true, priority: 3),
            Task(id: "2", title: String(localized: "给妈妈打电话"), due: .now, hasDueTime: false, priority: 0),
            Task(id: "3", title: String(localized: "取快递"), due: .now, hasDueTime: false, priority: 0),
        ],
        monthStart: .now, monthExpense: 4286.5, monthIncome: 12000, monthBudget: 6000, todayExpense: 35,
        upcoming: [
            Upcoming(id: "b", kind: .bill, name: String(localized: "信用卡还款"), date: .now.addingTimeInterval(86_400 * 2), amount: 2180,
                     currency: currency, symbol: "creditcard.fill"),
            Upcoming(id: "e", kind: .expiry, name: String(localized: "车险"), date: .now.addingTimeInterval(86_400 * 40), amount: nil,
                     currency: currency, symbol: "shield.fill"),
        ])
    }

    /// Tasks to show on `day`: due by its end, and not already ticked off on a widget.
    func tasks(dueBy day: Date, excluding done: Set<String>, calendar: Calendar = .current) -> [Task] {
        guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) else { return [] }
        return tasks.filter { task in
            guard let due = task.due, !done.contains(task.id) else { return false }
            return due < end
        }
    }
}

/// The shared folder and the hand-off between widgets and the app.
nonisolated enum WidgetStore {
    static let appGroup = "group.com.zengji.suikouji"

    enum Kind {
        static let todayTasks = "today-tasks"
        static let spending = "month-spending"
        static let upcoming = "upcoming"
        static let capture = "quick-capture"
        static let captureControl = "capture-control"
    }

    private static let snapshotName = "widget-snapshot.json"
    private static let pendingKey = "widget.pendingCompletions"

    private static var snapshotURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appending(path: snapshotName)
    }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func load() -> WidgetSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Returns false when the shared folder isn't available (no app-group entitlement).
    @discardableResult
    static func save(_ snapshot: WidgetSnapshot) -> Bool {
        guard let url = snapshotURL, let data = try? JSONEncoder().encode(snapshot) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Tasks ticked off on a widget that the app hasn't recorded yet.
    static func pendingCompletions() -> [String] {
        defaults?.stringArray(forKey: pendingKey) ?? []
    }

    static func addPendingCompletion(_ id: String) {
        var pending = pendingCompletions()
        guard !pending.contains(id) else { return }
        pending.append(id)
        defaults?.set(pending, forKey: pendingKey)
    }

    static func clearPendingCompletions(_ ids: [String]) {
        defaults?.set(pendingCompletions().filter { !ids.contains($0) }, forKey: pendingKey)
    }
}

/// How the capture sheet starts when something outside the app opens it.
enum CaptureStart: Equatable {
    /// Tidy this text straight away.
    case text(String)
    /// Start listening.
    case voice
}

/// "记一笔": opens the capture sheet with what was said, and AI tidies it for review there, the
/// same as typing it in the app. Without text it opens listening. Also what the Action Button
/// and the Control Center button run, so it's in the widget extension too; it always runs in the app.
struct CaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "记一笔"
    static let description = IntentDescription("把一句话交给随口记：AI 整理成待办、账目、账单、到期或笔记，你确认后再保存。不填内容就直接开始听。")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "内容")
    var text: String?

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let said = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        AppRouter.shared.startCapture(said.isEmpty ? .voice : .text(said))
        #endif
        return .result()
    }
}
