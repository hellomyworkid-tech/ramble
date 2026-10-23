import Foundation

/// "Remind me N days before the due date, at HH:mm." Used by bills and expiry items.
nonisolated struct ReminderRule: Codable, Hashable, Identifiable {
    var daysBefore: Int
    var hour: Int = 9
    var minute: Int = 0

    var id: Int { daysBefore }

    func fireDate(for dueDate: Date, calendar: Calendar = .current) -> Date? {
        let dueDay = calendar.startOfDay(for: dueDate)
        guard let day = calendar.date(byAdding: .day, value: -daysBefore, to: dueDay) else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    var timeText: String {
        String(format: "%d:%02d", hour, minute)
    }

    /// e.g. "提前 90 / 30 / 7 天 · 当天 9:00"
    static func summary(of rules: [ReminderRule]) -> String {
        guard !rules.isEmpty else { return String(localized: "不提醒") }
        let early = rules.map(\.daysBefore).filter { $0 > 0 }.sorted(by: >)
        var parts: [String] = []
        if !early.isEmpty {
            let days = early.map(String.init).joined(separator: " / ")
            parts.append(String(localized: "提前 \(days) 天"))
        }
        if let sameDay = rules.first(where: { $0.daysBefore == 0 }) {
            parts.append(String(localized: "当天 \(sameDay.timeText)"))
        }
        return parts.joined(separator: " · ")
    }

    static let presetDays = [0, 1, 3, 7, 30, 90]
}

nonisolated enum JSONStore {
    static func encode<T: Encodable>(_ value: T?) -> Data? {
        guard let value else { return nil }
        return try? JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
