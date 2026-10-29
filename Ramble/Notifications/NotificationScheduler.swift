import BackgroundTasks
import OSLog
import SwiftData
import UserNotifications

/// Keeps iOS's pending notifications in step with the data. Every reschedule
/// replaces the whole plan, so edits, deletions and payments are always reflected.
final class NotificationScheduler {
    static let shared = NotificationScheduler()
    static let refreshTaskID = "com.zengji.suikouji.refresh-reminders"
    static let reminderPrefix = "rem."
    static let snoozePrefix = "snooze."

    private let log = Logger(subsystem: "com.zengji.suikouji", category: "notifications")
    private(set) var container: ModelContainer?
    private var pendingReschedule: Task<Void, Never>?
    private var center: UNUserNotificationCenter { .current() }

    func configure(container: ModelContainer) {
        self.container = container
        center.delegate = NotificationHandler.shared
        center.setNotificationCategories(Self.categories)
    }

    /// Coalesces bursts of saves into one reschedule.
    func setNeedsReschedule() {
        pendingReschedule?.cancel()
        pendingReschedule = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await reschedule()
        }
    }

    /// Replaces every pending reminder with a fresh plan. Snoozed ones are kept.
    #if DEBUG
    /// App Store screenshots (`-startTab`): no permission alert over the page.
    private static let isTakingScreenshots = ProcessInfo.processInfo.arguments.contains("-startTab")
    #else
    private static let isTakingScreenshots = false
    #endif

    /// Asks for permission the first time there is something to remind about.
    @discardableResult
    func reschedule(now: Date = .now) async -> Int {
        guard let container else { return 0 }
        let context = container.mainContext
        if context.hasChanges { try? context.save() }
        let planned = plan(in: context, now: now)

        var status = await center.notificationSettings().authorizationStatus
        log.info("reschedule: \(planned.count) planned, authorization \(status.rawValue)")
        if status == .notDetermined, !planned.isEmpty, !Self.isTakingScreenshots {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                log.info("authorization request answered: \(granted)")
            } catch {
                log.error("authorization request failed: \(error.localizedDescription)")
            }
            status = await center.notificationSettings().authorizationStatus
        }
        guard [.authorized, .provisional, .ephemeral].contains(status) else { return 0 }

        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let snoozed = pending.filter { $0.hasPrefix(Self.snoozePrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { !$0.hasPrefix(Self.snoozePrefix) })

        let selected = ReminderPlanner.select(planned, now: now, limit: ReminderPlanner.limit - snoozed.count)
        for (index, reminder) in selected.enumerated() {
            try? await center.add(Self.request(for: reminder, identifier: "\(Self.reminderPrefix)\(index)"))
        }
        log.info("scheduled \(selected.count) reminders (\(snoozed.count) snoozed kept)")
        return selected.count
    }

    func plan(in context: ModelContext, now: Date) -> [PlannedReminder] {
        var reminders: [PlannedReminder] = []

        let tasks = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.isCompleted && $0.dueDate != nil }))) ?? []
        for task in tasks {
            guard let due = task.dueDate else { continue }
            reminders += ReminderPlanner.taskReminders(id: ModelRef.encode(task.persistentModelID), title: task.title, due: due,
                                                       hasTime: task.hasDueTime, minutesBefore: task.reminderMinutes, now: now)
        }

        let bills = (try? context.fetch(FetchDescriptor<Bill>(predicate: #Predicate { $0.isActive }))) ?? []
        for bill in bills {
            reminders += ReminderPlanner.billReminders(id: ModelRef.encode(bill.persistentModelID), name: bill.name, due: bill.nextDueDate,
                                                       amountText: bill.amount.money(bill.currencyCode), isEstimated: bill.isAmountEstimated,
                                                       rules: bill.reminderRules, now: now)
        }

        reminders += ReminderPlanner.reportReminders(weekly: ReportSettings.weeklyReminder, monthly: ReportSettings.monthlyReminder, now: now)

        let expiries = (try? context.fetch(FetchDescriptor<ExpiryItem>(predicate: #Predicate { !$0.isArchived }))) ?? []
        for item in expiries {
            reminders += ReminderPlanner.expiryReminders(id: ModelRef.encode(item.persistentModelID), name: item.name, expiry: item.expiryDate,
                                                         expiryText: item.expiryText, renewable: item.renewalMonths > 0,
                                                         rules: item.reminderRules, now: now)
        }
        return reminders
    }

    /// Re-posts a notification later without touching the rest of the plan.
    func snooze(_ payload: NotificationPayload, until date: Date) async {
        let reminder = PlannedReminder(target: PlannedReminder.Target(rawValue: payload.target) ?? .openApp, targetID: payload.id,
                                       fireDate: date, title: payload.title, body: payload.body,
                                       category: payload.category, threadID: payload.threadID)
        try? await center.add(Self.request(for: reminder, identifier: Self.snoozePrefix + UUID().uuidString))
    }

    static func request(for reminder: PlannedReminder, identifier: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        content.categoryIdentifier = reminder.category
        content.threadIdentifier = reminder.threadID
        content.userInfo = ["target": reminder.target.rawValue, "id": reminder.targetID]
        // Wall-clock components (no time zone) keep "9:00" meaning 9:00 after travel.
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
    }

    /// Asks iOS to wake the app now and then, so reminders beyond the 64-slot window get scheduled.
    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Calendar.current.date(byAdding: .hour, value: 12, to: .now)
        try? BGTaskScheduler.shared.submit(request)
    }

    static var categories: Set<UNNotificationCategory> {
        let complete = UNNotificationAction(identifier: NotificationAction.complete.rawValue, title: String(localized: "完成"))
        let snoozeHour = UNNotificationAction(identifier: NotificationAction.snoozeHour.rawValue, title: String(localized: "1 小时后再提醒"))
        let markPaid = UNNotificationAction(identifier: NotificationAction.markPaid.rawValue, title: String(localized: "标记已付"))
        let payInApp = UNNotificationAction(identifier: NotificationAction.payInApp.rawValue, title: String(localized: "填写金额并标记已付"),
                                            options: [.foreground])
        let renewed = UNNotificationAction(identifier: NotificationAction.renewed.rawValue, title: String(localized: "已续期"))
        let snoozeTomorrow = UNNotificationAction(identifier: NotificationAction.snoozeTomorrow.rawValue, title: String(localized: "明天再提醒"))
        typealias C = ReminderPlanner.Category
        return [
            UNNotificationCategory(identifier: C.task, actions: [complete, snoozeHour], intentIdentifiers: []),
            UNNotificationCategory(identifier: C.bill, actions: [markPaid, snoozeTomorrow], intentIdentifiers: []),
            UNNotificationCategory(identifier: C.billEstimated, actions: [payInApp, snoozeTomorrow], intentIdentifiers: []),
            UNNotificationCategory(identifier: C.expiry, actions: [snoozeTomorrow], intentIdentifiers: []),
            UNNotificationCategory(identifier: C.expiryRenewable, actions: [renewed, snoozeTomorrow], intentIdentifiers: []),
            UNNotificationCategory(identifier: C.openApp, actions: [], intentIdentifiers: []),
        ]
    }
}

nonisolated enum NotificationAction: String {
    case complete = "COMPLETE"
    case snoozeHour = "SNOOZE_HOUR"
    case markPaid = "MARK_PAID"
    case payInApp = "PAY_IN_APP"
    case renewed = "RENEWED"
    case snoozeTomorrow = "SNOOZE_TOMORROW"
}

/// The Sendable parts of a notification response.
nonisolated struct NotificationPayload {
    let action: String
    let target: String
    let id: String
    let title: String
    let body: String
    let category: String
    let threadID: String
}

enum NotificationActions {
    /// Applies an action button to the data. Returns true when something changed.
    @discardableResult
    static func apply(_ action: NotificationAction, target: PlannedReminder.Target, id: String,
                      in context: ModelContext, now: Date = .now) -> Bool {
        switch (action, target) {
        case (.complete, .task):
            guard let task = ModelRef.fetch(TaskItem.self, id, in: context), !task.isCompleted else { return false }
            task.toggleCompletion(now: now)
        case (.markPaid, .bill):
            guard let bill = ModelRef.fetch(Bill.self, id, in: context), bill.isActive else { return false }
            bill.markPaid(amount: bill.amount, on: now, from: bill.account, recordEntry: bill.autoRecord, in: context)
        case (.renewed, .expiry):
            guard let item = ModelRef.fetch(ExpiryItem.self, id, in: context), item.renewalMonths > 0 else { return false }
            item.renew()
        default:
            return false
        }
        try? context.save()
        return true
    }
}

final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHandler()

    // The completion-handler forms rather than the async ones: an async delegate method hands its
    // completion back on whatever thread it finished on, and UIKit asserts the main thread there.
    // Tapping a reminder crashed the app as it opened.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let payload = NotificationPayload(
            action: response.actionIdentifier,
            target: content.userInfo["target"] as? String ?? "",
            id: content.userInfo["id"] as? String ?? "",
            title: content.title,
            body: content.body,
            category: content.categoryIdentifier,
            threadID: content.threadIdentifier
        )
        Task { @MainActor in
            await Self.handle(payload)
            completionHandler()
        }
    }

    @MainActor
    static func handle(_ payload: NotificationPayload, now: Date = .now) async {
        Logger(subsystem: "com.zengji.suikouji", category: "notifications")
            .info("response \(payload.action) for \(payload.target)")
        let scheduler = NotificationScheduler.shared
        let target = PlannedReminder.Target(rawValue: payload.target)
        switch payload.action {
        case UNNotificationDefaultActionIdentifier:
            AppRouter.shared.open(target, id: payload.id)
        case NotificationAction.payInApp.rawValue:
            AppRouter.shared.open(.bill, id: payload.id, pay: true)
        case NotificationAction.snoozeHour.rawValue:
            await scheduler.snooze(payload, until: now.addingTimeInterval(3600))
        case NotificationAction.snoozeTomorrow.rawValue:
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
            let nine = Calendar.current.date(bySettingHour: ReminderPlanner.taskHour, minute: 0, second: 0, of: tomorrow) ?? tomorrow
            await scheduler.snooze(payload, until: nine)
        default:
            guard let action = NotificationAction(rawValue: payload.action), let target,
                  let context = scheduler.container?.mainContext
            else { return }
            if NotificationActions.apply(action, target: target, id: payload.id, in: context, now: now) {
                await scheduler.reschedule()
            }
        }
    }
}

/// Encodes a model's identity into a notification's userInfo and finds it again.
nonisolated enum ModelRef {
    static func encode(_ id: PersistentIdentifier) -> String {
        (try? JSONEncoder().encode(id))?.base64EncodedString() ?? ""
    }

    static func decode(_ string: String) -> PersistentIdentifier? {
        guard let data = Data(base64Encoded: string) else { return nil }
        return try? JSONDecoder().decode(PersistentIdentifier.self, from: data)
    }

    /// Fetches rather than `model(for:)` so a deleted record comes back as nil.
    @MainActor
    static func fetch<T: PersistentModel>(_ type: T.Type, _ string: String, in context: ModelContext) -> T? {
        guard let id = decode(string) else { return nil }
        var descriptor = FetchDescriptor<T>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
