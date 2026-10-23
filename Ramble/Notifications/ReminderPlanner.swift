import Foundation

/// One local notification to schedule.
nonisolated struct PlannedReminder: Equatable {
    enum Target: String {
        case task, bill, expiry, openApp
        /// The weekly or monthly report; `targetID` is "week" or "month".
        case report
    }

    let target: Target
    /// The model's encoded PersistentIdentifier; empty for the open-app nudge.
    let targetID: String
    let fireDate: Date
    let title: String
    let body: String
    let category: String
    let threadID: String
}

/// Pure planning: which reminders exist and which 64 iOS gets to hold.
nonisolated enum ReminderPlanner {
    /// iOS keeps at most 64 pending local notifications per app.
    static let limit = 64
    /// Date-only tasks remind at this hour.
    static let taskHour = 9

    enum Category {
        static let task = "TASK"
        static let bill = "BILL"
        static let billEstimated = "BILL_ESTIMATED"
        static let expiry = "EXPIRY"
        static let expiryRenewable = "EXPIRY_RENEWABLE"
        static let openApp = "OPEN_APP"
    }

    // MARK: Tasks

    /// Timed tasks fire `minutes` before the due time; date-only tasks fire at 9:00,
    /// `minutes` before that (1440 = the day before).
    static func taskFireDate(due: Date, hasTime: Bool, minutesBefore minutes: Int, calendar: Calendar = .current) -> Date? {
        let anchor = hasTime ? due : (calendar.date(bySettingHour: taskHour, minute: 0, second: 0, of: due) ?? due)
        return calendar.date(byAdding: .minute, value: -minutes, to: anchor)
    }

    static func taskReminders(id: String, title: String, due: Date, hasTime: Bool, minutesBefore: [Int],
                              now: Date, calendar: Calendar = .current) -> [PlannedReminder] {
        Set(minutesBefore.filter { $0 >= 0 }).sorted().compactMap { minutes in
            guard let fireDate = taskFireDate(due: due, hasTime: hasTime, minutesBefore: minutes, calendar: calendar),
                  fireDate > now
            else { return nil }
            let body: String
            if hasTime {
                let time = due.formatted(date: .omitted, time: .shortened)
                body = minutes == 0
                    ? String(localized: "\(time) 到时间了")
                    : String(localized: "\(Self.leadText(minutes: minutes))到期 · \(time)")
            } else {
                body = minutes >= 1440 ? String(localized: "明天要做") : String(localized: "今天要做")
            }
            return PlannedReminder(target: .task, targetID: id, fireDate: fireDate, title: title, body: body,
                                   category: Category.task, threadID: "task-\(id)")
        }
    }

    /// "15 分钟", "1 小时", "1 天"
    static func durationText(minutes: Int) -> String {
        if minutes > 0, minutes % 1440 == 0 { return String(localized: "\(minutes / 1440) 天") }
        if minutes > 0, minutes % 60 == 0 { return String(localized: "\(minutes / 60) 小时") }
        return String(localized: "\(minutes) 分钟")
    }

    /// "15 分钟后", "1 小时后", "1 天后"
    static func leadText(minutes: Int) -> String {
        String(localized: "\(durationText(minutes: minutes))后")
    }

    // MARK: Bills and expiry items

    static func billReminders(id: String, name: String, due: Date, amountText: String, isEstimated: Bool,
                              rules: [ReminderRule], now: Date, calendar: Calendar = .current) -> [PlannedReminder] {
        rules.compactMap { rule in
            guard let fireDate = rule.fireDate(for: due, calendar: calendar), fireDate > now else { return nil }
            let when = rule.daysBefore == 0 ? String(localized: "今天到期") : String(localized: "\(rule.daysBefore) 天后到期")
            var body = "\(isEstimated ? String(localized: "约 ") : "")\(amountText) · \(DayText.dayWithWeekday(due))"
            if isEstimated { body += String(localized: " · 支付时填实际金额") }
            return PlannedReminder(target: .bill, targetID: id, fireDate: fireDate, title: "\(name) · \(when)", body: body,
                                   category: isEstimated ? Category.billEstimated : Category.bill, threadID: "bill-\(id)")
        }
    }

    static func expiryReminders(id: String, name: String, expiry: Date, expiryText: String, renewable: Bool,
                                rules: [ReminderRule], now: Date, calendar: Calendar = .current) -> [PlannedReminder] {
        rules.compactMap { rule in
            guard let fireDate = rule.fireDate(for: expiry, calendar: calendar), fireDate > now else { return nil }
            let when = rule.daysBefore == 0 ? String(localized: "今天到期") : String(localized: "还有 \(rule.daysBefore) 天到期")
            let body = rule.daysBefore >= 30
                ? String(localized: "\(expiryText) 到期，记得提前办理续期")
                : String(localized: "\(expiryText) 到期")
            return PlannedReminder(target: .expiry, targetID: id, fireDate: fireDate, title: "\(name) · \(when)", body: body,
                                   category: renewable ? Category.expiryRenewable : Category.expiry, threadID: "expiry-\(id)")
        }
    }

    /// "上周周报 is ready" on Mondays and "10月月报" on the 1st, at 9:00.
    static func reportReminders(weekly: Bool, monthly: Bool, now: Date, calendar: Calendar = PeriodResolver.calendar) -> [PlannedReminder] {
        var reminders: [PlannedReminder] = []
        if weekly, let monday = calendar.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 2),
                                                   matchingPolicy: .nextTime) {
            reminders.append(PlannedReminder(target: .report, targetID: "week", fireDate: monday,
                                             title: String(localized: "上周周报"),
                                             body: String(localized: "上周花了多少、钱花在哪、完成了几件事，点开看看。"),
                                             category: Category.openApp, threadID: "report"))
        }
        if monthly, let first = calendar.nextDate(after: now, matching: DateComponents(day: 1, hour: 9, minute: 0), matchingPolicy: .nextTime),
           let lastMonth = calendar.date(byAdding: .day, value: -1, to: first) {
            let month = lastMonth.formatted(.dateTime.month(.abbreviated))
            reminders.append(PlannedReminder(target: .report, targetID: "month", fireDate: first,
                                             title: String(localized: "\(month)月报"),
                                             body: String(localized: "上个月的收支、预算和完成的事都整理好了。"),
                                             category: Category.openApp, threadID: "report"))
        }
        return reminders
    }

    // MARK: Selection

    /// The soonest future reminders that fit in `limit`. When some don't fit, the last
    /// slot becomes a nudge to open the app (which schedules the rest), timed just
    /// after the last reminder that did fit.
    static func select(_ reminders: [PlannedReminder], now: Date, limit: Int = limit) -> [PlannedReminder] {
        let upcoming = reminders.filter { $0.fireDate > now }.sorted { $0.fireDate < $1.fireDate }
        guard limit > 0 else { return [] }
        guard upcoming.count > limit else { return upcoming }
        let kept = Array(upcoming.prefix(limit - 1))
        let nudgeDate = (kept.last?.fireDate ?? now).addingTimeInterval(60)
        let nudge = PlannedReminder(target: .openApp, targetID: "", fireDate: nudgeDate,
                                    title: String(localized: "打开随口记继续接收提醒"),
                                    body: String(localized: "后面还有提醒没排上，打开一下 App 就会自动安排。"),
                                    category: Category.openApp, threadID: "open-app")
        return kept + [nudge]
    }
}
