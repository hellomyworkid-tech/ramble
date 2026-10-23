import Foundation

/// A repeat rule for tasks and bills. Stored on models as JSON so it survives
/// SwiftData + CloudKit without composite-attribute quirks.
nonisolated struct Recurrence: Codable, Hashable {
    enum Frequency: String, Codable, CaseIterable, Identifiable {
        case daily, weekly, monthly, yearly

        var id: String { rawValue }

    }

    var frequency: Frequency
    var interval: Int = 1
    /// Weekly only. Calendar weekday numbers (1 = Sunday … 7 = Saturday).
    /// Empty means "the same weekday as the current occurrence".
    var weekdays: [Int] = []
    /// Monthly only. 1…31, or `lastDayOfMonth`. Days past the end of a short
    /// month clamp to its last day without drifting later months.
    var monthDay: Int?
    var endDate: Date?

    static let lastDayOfMonth = -1
    static let workdays = [2, 3, 4, 5, 6]

    static let daily = Recurrence(frequency: .daily)
    static let workdaysOnly = Recurrence(frequency: .weekly, weekdays: workdays)
    static let weekly = Recurrence(frequency: .weekly)
    static let biweekly = Recurrence(frequency: .weekly, interval: 2)
    static let yearly = Recurrence(frequency: .yearly)

    static func monthly(day: Int? = nil, every interval: Int = 1) -> Recurrence {
        Recurrence(frequency: .monthly, interval: interval, monthDay: day)
    }

    /// Pins the month day to the anchor so "monthly on the 31st" keeps landing on
    /// the 31st (or the month's last day) rather than drifting to the 28th.
    func normalized(anchor: Date, calendar: Calendar = .current) -> Recurrence {
        var copy = self
        copy.interval = max(1, interval)
        if frequency == .monthly, monthDay == nil {
            copy.monthDay = calendar.component(.day, from: anchor)
        }
        if frequency != .weekly { copy.weekdays = [] }
        if frequency != .monthly { copy.monthDay = nil }
        copy.weekdays = Array(Set(copy.weekdays)).sorted()
        return copy
    }

    /// The occurrence that follows `current`, keeping its time of day.
    /// Returns nil once the rule has ended.
    func nextOccurrence(after current: Date, calendar: Calendar = .current) -> Date? {
        let step = max(1, interval)
        let next: Date?
        switch frequency {
        case .daily:
            next = calendar.date(byAdding: .day, value: step, to: current)
        case .weekly:
            if weekdays.isEmpty || step > 1 {
                next = calendar.date(byAdding: .weekOfYear, value: step, to: current)
            } else {
                next = Self.nextMatchingWeekday(after: current, in: Set(weekdays), calendar: calendar)
            }
        case .monthly:
            let day = monthDay ?? calendar.component(.day, from: current)
            next = Self.date(in: current, addingMonths: step, day: day, calendar: calendar)
        case .yearly:
            next = calendar.date(byAdding: .year, value: step, to: current)
        }
        guard let next else { return nil }
        if let endDate, next > endDate { return nil }
        return next
    }

    /// First date on or after `date` whose month day is `day`, at `date`'s time.
    static func firstMonthly(day: Int, onOrAfter date: Date, calendar: Calendar = .current) -> Date {
        let thisMonth = Self.date(in: date, addingMonths: 0, day: day, calendar: calendar) ?? date
        if calendar.startOfDay(for: thisMonth) >= calendar.startOfDay(for: date) {
            return thisMonth
        }
        return Self.date(in: date, addingMonths: 1, day: day, calendar: calendar) ?? date
    }

    private static func nextMatchingWeekday(after date: Date, in weekdays: Set<Int>, calendar: Calendar) -> Date? {
        var candidate = date
        for _ in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: 1, to: candidate) else { return nil }
            candidate = day
            if weekdays.contains(calendar.component(.weekday, from: candidate)) {
                return candidate
            }
        }
        return nil
    }

    private static func date(in reference: Date, addingMonths months: Int, day: Int, calendar: Calendar) -> Date? {
        var parts = calendar.dateComponents([.year, .month, .hour, .minute, .second], from: reference)
        parts.day = 1
        guard let firstOfMonth = calendar.date(from: parts),
              let targetMonth = calendar.date(byAdding: .month, value: months, to: firstOfMonth),
              let days = calendar.range(of: .day, in: .month, for: targetMonth)
        else { return nil }
        let resolved = day == lastDayOfMonth ? days.count : min(max(day, 1), days.count)
        return calendar.date(byAdding: .day, value: resolved - 1, to: targetMonth)
    }
}

extension Recurrence {
    /// "每 3 天" for the interval stepper, whatever the interval.
    var everyText: String {
        switch frequency {
        case .daily: String(localized: "每 \(interval) 天")
        case .weekly: String(localized: "每 \(interval) 周")
        case .monthly: String(localized: "每 \(interval) 个月")
        case .yearly: String(localized: "每 \(interval) 年")
        }
    }

    /// Short human description, e.g. "每月 15 日", "工作日", "每两周".
    func summary(anchor: Date? = nil, calendar: Calendar = .current) -> String {
        let n = max(1, interval)
        switch frequency {
        case .daily:
            return n == 1 ? String(localized: "每天") : String(localized: "每 \(n) 天")
        case .weekly:
            if n == 1, weekdays.sorted() == Self.workdays {
                return String(localized: "工作日")
            }
            if n == 1, !weekdays.isEmpty {
                let symbols = calendar.shortStandaloneWeekdaySymbols
                // Present Monday-first, which is how people read a week here.
                let ordered = weekdays.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }
                return ordered.map { symbols[$0 - 1] }.joined(separator: AppLanguage.isChinese ? "、" : ", ")
            }
            switch n {
            case 1: return String(localized: "每周")
            case 2: return String(localized: "每两周")
            default: return String(localized: "每 \(n) 周")
            }
        case .monthly:
            let day = monthDay ?? anchor.map { calendar.component(.day, from: $0) }
            let dayText: String
            if day == Self.lastDayOfMonth {
                dayText = String(localized: "最后一天")
            } else if let day {
                dayText = String(localized: "\(day) 日")
            } else {
                dayText = ""
            }
            let prefix = n == 1 ? String(localized: "每月") : String(localized: "每 \(n) 个月")
            return dayText.isEmpty ? prefix : "\(prefix) \(dayText)"
        case .yearly:
            let prefix = n == 1 ? String(localized: "每年") : String(localized: "每 \(n) 年")
            guard let anchor else { return prefix }
            return "\(prefix) \(anchor.formatted(.dateTime.month().day()))"
        }
    }
}
