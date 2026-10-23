import AppIntents
import SwiftUI
import UserNotifications
import WidgetKit

@main
struct RambleWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TodayTasksWidget()
        SpendingWidget()
        UpcomingWidget()
        QuickCaptureWidget()
        CaptureControl()
    }
}

// MARK: - Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    /// Nil until the app has run once with widgets in place.
    let snapshot: WidgetSnapshot?
    /// Ticked off on a widget, not yet recorded by the app.
    let done: Set<String>
}

/// Every widget reads the same summary; new entries at each due time today and at midnight keep
/// "overdue" and "today" right while the app isn't running.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .placeholder, done: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date.now
        let calendar = Calendar.current
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        let snapshot = WidgetStore.load()
        let dueTimes = (snapshot?.tasks ?? []).compactMap { $0.hasDueTime ? $0.due : nil }.filter { $0 > now && $0 < midnight }
        let dates = Array(Set([now, midnight] + dueTimes)).sorted().prefix(12)
        let done = Set(WidgetStore.pendingCompletions())
        let entries = dates.map { SnapshotEntry(date: $0, snapshot: snapshot, done: done) }
        completion(Timeline(entries: entries, policy: .after(midnight.addingTimeInterval(60))))
    }

    private func entry(at date: Date) -> SnapshotEntry {
        SnapshotEntry(date: date, snapshot: WidgetStore.load(), done: Set(WidgetStore.pendingCompletions()))
    }
}

// MARK: - Style

enum WidgetColor {
    static let tasks = Color(red: 0.04, green: 0.40, blue: 0.85)
    static let money = Color(red: 0.14, green: 0.54, blue: 0.24)
    static let bills = Color(red: 0.76, green: 0.34, blue: 0.05)
    static let expiry = Color(red: 0.54, green: 0.27, blue: 0.67)
    static let warning = Color(red: 0.84, green: 0.27, blue: 0.0)
}

extension Decimal {
    /// The person's own currency as plain 「¥」; others keep the form that tells them apart (US$).
    func widgetMoney(_ code: String, cents: Bool = false, narrow: Bool = true) -> String {
        var style = Decimal.FormatStyle.Currency(code: code).precision(.fractionLength(cents ? 2 : 0))
        if narrow { style = style.presentation(.narrow) }
        return formatted(style)
    }
}

/// Shown before the app has written anything for the widgets.
struct OpenAppHint: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.up.forward.app")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("打开随口记后显示")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Today's tasks

struct TodayTasksWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.Kind.todayTasks, provider: SnapshotProvider()) { entry in
            TodayTasksView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "ramble://tasks"))
        }
        .configurationDisplayName("今日待办")
        .description("今天要做的事，点圆圈直接完成。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

struct TodayTasksView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    private var tasks: [WidgetSnapshot.Task] {
        entry.snapshot?.tasks(dueBy: entry.date, excluding: entry.done) ?? []
    }

    private var limit: Int {
        switch family {
        case .systemLarge: 8
        case .systemMedium: 3
        default: 3
        }
    }

    var body: some View {
        if entry.snapshot == nil {
            OpenAppHint()
        } else if family == .accessoryRectangular {
            lockScreen
        } else {
            VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 8) {
                HStack {
                    Label("今天", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(WidgetColor.tasks)
                    Spacer()
                    if !tasks.isEmpty {
                        Text("\(tasks.count)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if tasks.isEmpty {
                    Spacer()
                    Text("今天没有待办")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ForEach(tasks.prefix(limit)) { task in
                        TaskRow(task: task, now: entry.date, compact: family == .systemSmall)
                    }
                    Spacer(minLength: 0)
                    if tasks.count > limit {
                        Text("还有 \(tasks.count - limit) 项")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var lockScreen: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(tasks.isEmpty ? String(localized: "今天没有待办") : String(localized: "今天 \(tasks.count) 项待办"))
                .font(.headline)
                .widgetAccentable()
            ForEach(tasks.prefix(2)) { task in
                Text(task.title)
                    .font(.caption)
                    .lineLimit(1)
                    .privacySensitive()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TaskRow: View {
    let task: WidgetSnapshot.Task
    let now: Date
    let compact: Bool

    private var isOverdue: Bool {
        guard let due = task.due else { return false }
        return task.hasDueTime ? due < now : due < Calendar.current.startOfDay(for: now)
    }

    private var dueText: String? {
        guard let due = task.due else { return nil }
        if due < Calendar.current.startOfDay(for: now) {
            return String(localized: "已过期 · \(due.formatted(.dateTime.month().day()))")
        }
        return task.hasDueTime ? due.formatted(date: .omitted, time: .shortened) : nil
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(intent: CompleteTaskIntent(id: task.id)) {
                Image(systemName: "circle")
                    .font(.body)
                    .foregroundStyle(task.priority >= 3 ? WidgetColor.warning : WidgetColor.tasks)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("完成「\(task.title)」")
            VStack(alignment: .leading, spacing: 0) {
                Text(task.title)
                    .font(compact ? .caption : .subheadline)
                    .lineLimit(1)
                    .privacySensitive()
                if let dueText {
                    Text(dueText)
                        .font(.caption2)
                        .foregroundStyle(isOverdue ? WidgetColor.warning : .secondary)
                }
            }
        }
    }
}

/// Ticks a task off from the widget. The widget can't write to the app's database, so this
/// records it for the app (which applies it when it next runs) and drops the task's pending
/// reminders so they don't go off meanwhile.
struct CompleteTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "完成待办"
    static let isDiscoverable = false

    @Parameter(title: "待办")
    var taskID: String

    init() {}

    init(id: String) {
        taskID = id
    }

    func perform() async throws -> some IntentResult {
        WidgetStore.addPendingCompletion(taskID)
        let center = UNUserNotificationCenter.current()
        let thread = "task-\(taskID)"
        let ids = await center.pendingNotificationRequests().filter { $0.content.threadIdentifier == thread }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: ids)
        // The system redraws the tapped widget; the others (and a second copy) need asking.
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetStore.Kind.todayTasks)
        return .result()
    }
}

// MARK: - Spending

struct SpendingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.Kind.spending, provider: SnapshotProvider()) { entry in
            SpendingView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "ramble://ledger"))
        }
        .configurationDisplayName("本月支出")
        .description("这个月花了多少，预算还剩多少。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct SpendingView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    private var calendar: Calendar { .current }

    /// A new month or day starts at zero, even before the app has run.
    private var monthExpense: Decimal {
        guard let snapshot = entry.snapshot, calendar.isDate(snapshot.monthStart, equalTo: entry.date, toGranularity: .month) else { return 0 }
        return snapshot.monthExpense
    }

    private var monthIncome: Decimal {
        guard let snapshot = entry.snapshot, calendar.isDate(snapshot.monthStart, equalTo: entry.date, toGranularity: .month) else { return 0 }
        return snapshot.monthIncome
    }

    private var todayExpense: Decimal {
        guard let snapshot = entry.snapshot, calendar.isDate(snapshot.generatedAt, inSameDayAs: entry.date) else { return 0 }
        return snapshot.todayExpense
    }

    private var currency: String { entry.snapshot?.currency ?? "CNY" }

    private var fraction: Double? {
        guard let budget = entry.snapshot?.monthBudget, budget > 0 else { return nil }
        return NSDecimalNumber(decimal: monthExpense / budget).doubleValue
    }

    private var barColor: Color {
        guard let fraction else { return WidgetColor.money }
        return fraction >= 1 ? WidgetColor.warning : (fraction >= 0.8 ? WidgetColor.bills : WidgetColor.money)
    }

    private var budgetText: String? {
        guard let budget = entry.snapshot?.monthBudget, budget > 0 else { return nil }
        let left = budget - monthExpense
        return left >= 0 ? String(localized: "剩 \(left.widgetMoney(currency))") : String(localized: "超支 \((-left).widgetMoney(currency))")
    }

    var body: some View {
        if entry.snapshot == nil {
            OpenAppHint()
        } else {
            switch family {
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .systemMedium: medium
            default: small
            }
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("本月支出", systemImage: "yensign.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(WidgetColor.money)
            Spacer(minLength: 0)
            Text(monthExpense.widgetMoney(currency))
                .font(.title2.weight(.bold).monospacedDigit())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .privacySensitive()
            if let fraction {
                ProgressView(value: min(1, max(0, fraction)))
                    .tint(barColor)
            }
            Text(budgetText ?? String(localized: "今天 \(todayExpense.widgetMoney(currency))"))
                .font(.caption2)
                .foregroundStyle(fraction.map { $0 >= 1 } == true ? WidgetColor.warning : .secondary)
                .privacySensitive()
        }
    }

    private var medium: some View {
        HStack(spacing: 16) {
            small
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                figure(String(localized: "今天支出"), todayExpense)
                figure(String(localized: "本月收入"), monthIncome)
                if let budget = entry.snapshot?.monthBudget, budget > 0 {
                    figure(String(localized: "每月预算"), budget)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func figure(_ title: String, _ amount: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(amount.widgetMoney(currency))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .privacySensitive()
        }
    }

    @ViewBuilder
    private var circular: some View {
        if let fraction {
            Gauge(value: min(1, max(0, fraction))) {
                Text("预算")
            } currentValueLabel: {
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .privacySensitive()
            }
            .gaugeStyle(.accessoryCircularCapacity)
        } else {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "yensign")
                        .font(.caption)
                    Text(monthExpense.formatted(.number.notation(.compactName)))
                        .font(.caption2.weight(.semibold))
                        .minimumScaleFactor(0.6)
                        .privacySensitive()
                }
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("本月支出")
                .font(.caption)
                .widgetAccentable()
            Text(monthExpense.widgetMoney(currency))
                .font(.headline.monospacedDigit())
                .privacySensitive()
            if let budgetText {
                Text(budgetText)
                    .font(.caption2)
                    .privacySensitive()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Upcoming bills and expiry dates

struct UpcomingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.Kind.upcoming, provider: SnapshotProvider()) { entry in
            UpcomingView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "ramble://reminders"))
        }
        .configurationDisplayName("即将到期")
        .description("快到期的账单、证件和保险。")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct UpcomingView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    private var items: [WidgetSnapshot.Upcoming] {
        let start = Calendar.current.startOfDay(for: entry.date)
        return (entry.snapshot?.upcoming ?? []).filter { $0.date >= start }
    }

    var body: some View {
        if entry.snapshot == nil {
            OpenAppHint()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("即将到期", systemImage: "calendar.badge.clock")
                    .font(.headline)
                    .foregroundStyle(WidgetColor.bills)
                if items.isEmpty {
                    Spacer()
                    Text("近期没有要付的账单或到期的东西")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ForEach(items.prefix(family == .systemLarge ? 7 : 3)) { item in
                        UpcomingRow(item: item, now: entry.date, baseCurrency: entry.snapshot?.currency ?? "")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

struct UpcomingRow: View {
    let item: WidgetSnapshot.Upcoming
    let now: Date
    var baseCurrency = ""

    private var days: Int {
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: item.date)).day ?? 0
    }

    private var dayText: String {
        switch days {
        case 0: String(localized: "今天")
        case 1: String(localized: "明天")
        case 2: String(localized: "后天")
        default: String(localized: "\(days) 天后")
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.caption)
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(item.kind == .bill ? WidgetColor.bills : WidgetColor.expiry, in: .rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .privacySensitive()
                Text("\(item.date.formatted(.dateTime.month().day())) · \(dayText)")
                    .font(.caption2)
                    .foregroundStyle(days <= 2 ? WidgetColor.warning : .secondary)
            }
            Spacer()
            if let amount = item.amount, amount > 0 {
                Text(amount.widgetMoney(item.currency, cents: true, narrow: item.currency == baseCurrency))
                    .font(.subheadline.monospacedDigit())
                    .privacySensitive()
            }
        }
    }
}

// MARK: - Quick capture

struct QuickCaptureWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.Kind.capture, provider: SnapshotProvider()) { _ in
            QuickCaptureView()
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "ramble://capture"))
        }
        .configurationDisplayName("记一下")
        .description("点一下直接开始说，AI 帮你整理成待办、账目和提醒。")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

struct QuickCaptureView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .accessoryCircular {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill")
                    .font(.title3)
                    .widgetAccentable()
            }
            .accessibilityLabel("记一下")
        } else {
            VStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .font(.title)
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(WidgetColor.tasks, in: .circle)
                Text("记一下")
                    .font(.headline)
                Text("说一句，AI 帮你记")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Control Center, the Lock Screen and the Action Button: opens the app listening.
struct CaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetStore.Kind.captureControl) {
            ControlWidgetButton(action: CaptureIntent()) {
                Label("记一下", systemImage: "mic.fill")
            }
        }
        .displayName("随口记 · 记一下")
        .description("打开随口记，直接开始听你说。")
    }
}
