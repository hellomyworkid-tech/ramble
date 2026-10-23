import Foundation

/// Turns spoken Chinese time words (下周三, 三个月以后, 下周四下午三点, 月底前, 10月15号) into a
/// date. Small on-device models copy these words reliably but get the arithmetic wrong, so they
/// hand over the words and this does the counting.
nonisolated struct SpokenDate: Equatable {
    var date: Date
    var hasTime: Bool
    /// Only the month (or a "half a year from now") is known.
    var isApproximate: Bool

    static func resolve(_ text: String, now: Date = .now, calendar: Calendar = .current) -> SpokenDate? {
        let words = normalizedNumbers(text.replacingOccurrences(of: " ", with: ""))
        var calendar = calendar
        calendar.firstWeekday = 2  // Chinese weeks start on Monday: 下周 is the week after this one.
        let today = calendar.startOfDay(for: now)

        guard var result = day(in: words, today: today, calendar: calendar) else {
            return english(text, now: now)
        }
        if let (hour, minute) = time(in: words) {
            result.date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: result.date) ?? result.date
            result.hasTime = true
        }
        return result
    }

    // MARK: Day

    private static func day(in words: String, today: Date, calendar: Calendar) -> SpokenDate? {
        func plain(_ date: Date?) -> SpokenDate? { date.map { SpokenDate(date: $0, hasTime: false, isApproximate: false) } }
        func add(_ component: Calendar.Component, _ value: Int) -> Date? { calendar.date(byAdding: component, value: value, to: today) }

        // Explicit dates first: 2026年3月1日, 明年3月, 10月15号, 15号.
        if let match = words.firstMatch(of: #/(?:(\d{4})年|(明年|今年|后年))?(\d{1,2})月(?:(\d{1,2})[日号])?/#) {
            let year: Int? = match.1.flatMap { Int($0) } ?? match.2.map { word in
                calendar.component(.year, from: today) + (word == "明年" ? 1 : word == "后年" ? 2 : 0)
            }
            guard let month = Int(match.3), (1...12).contains(month) else { return nil }
            let dayNumber = match.4.flatMap { Int($0) }
            var components = DateComponents(year: year ?? calendar.component(.year, from: today), month: month, day: dayNumber ?? 1)
            guard var date = calendar.date(from: components) else { return nil }
            if year == nil, date < today {
                components.year = (components.year ?? 0) + 1
                date = calendar.date(from: components) ?? date
            }
            return SpokenDate(date: date, hasTime: false, isApproximate: dayNumber == nil)
        }

        if words.contains("大后天") { return plain(add(.day, 3)) }
        if words.contains("后天") { return plain(add(.day, 2)) }
        if words.contains("明天") || words.contains("明日") || words.contains("明早") || words.contains("明晚") { return plain(add(.day, 1)) }
        if words.contains("今天") || words.contains("今日") || words.contains("今晚") || words.contains("今早") { return plain(today) }
        if words.contains("前天") { return plain(add(.day, -2)) }
        if words.contains("昨天") || words.contains("昨日") || words.contains("昨晚") { return plain(add(.day, -1)) }

        // 下周三, 这周五, 下下周一, 周日.
        if let match = words.firstMatch(of: #/(下下|下|这|本|上)?(?:个)?(?:周|星期|礼拜)([一二三四五六日天1-7])/#) {
            let weekday = weekdayIndex(String(match.2))  // 1 = Monday … 7 = Sunday
            let weekOffset: Int? = switch match.1.map(String.init) {
            case "下下": 2
            case "下": 1
            case "这", "本": 0
            case "上": -1
            default: nil
            }
            let thisMonday = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
            if let weekOffset {
                return plain(calendar.date(byAdding: .day, value: weekOffset * 7 + weekday - 1, to: thisMonday))
            }
            // Just 周三: the next one, today included.
            var date = calendar.date(byAdding: .day, value: weekday - 1, to: thisMonday) ?? today
            if date < today { date = calendar.date(byAdding: .day, value: 7, to: date) ?? date }
            return plain(date)
        }

        // N天/周/个月/年 后, 半个月后, 半年后.
        if let match = words.firstMatch(of: #/(\d+|半)(?:个)?(天|日|周|星期|礼拜|月|年)(?:以后|之后|后)/#) {
            let half = match.1 == "半"
            let count = Int(match.1) ?? 0
            switch match.2 {
            case "天", "日": return plain(add(.day, count))
            case "周", "星期", "礼拜": return plain(add(.day, half ? 3 : count * 7))
            case "月": return half ? plain(add(.day, 15)) : SpokenDate(date: add(.month, count) ?? today, hasTime: false, isApproximate: false)
            default: return half ? SpokenDate(date: add(.month, 6) ?? today, hasTime: false, isApproximate: true)
                                 : plain(add(.year, count))
            }
        }
        if let match = words.firstMatch(of: #/过(\d+)天/#), let count = Int(match.1) { return plain(add(.day, count)) }

        // Month edges: 月底(前), 下个月初, 下个月15号, 年底.
        let nextMonth = words.contains("下个月") || words.contains("下月")
        let monthStart = calendar.dateInterval(of: .month, for: nextMonth ? (add(.month, 1) ?? today) : today)
        if let match = words.firstMatch(of: #/(\d{1,2})[号日]/#), let dayNumber = Int(match.1), (1...31).contains(dayNumber) {
            var components = calendar.dateComponents([.year, .month], from: monthStart?.start ?? today)
            components.day = dayNumber
            guard var date = calendar.date(from: components) else { return nil }
            if !nextMonth, date < today { date = calendar.date(byAdding: .month, value: 1, to: date) ?? date }
            return plain(date)
        }
        if words.contains("月底") || words.contains("月末") {
            return plain(monthStart.flatMap { calendar.date(byAdding: .day, value: -1, to: $0.end) })
        }
        if nextMonth, words.contains("月初") { return plain(monthStart?.start) }
        if words.contains("年底") || words.contains("年末") {
            let year = calendar.component(.year, from: today)
            return plain(calendar.date(from: DateComponents(year: year, month: 12, day: 31)))
        }
        if nextMonth { return SpokenDate(date: monthStart?.start ?? today, hasTime: false, isApproximate: true) }
        return nil
    }

    /// "next Wednesday at 3pm", "tomorrow", "Oct 15": the system's detector reads English time
    /// words. It counts from the real present, so only when `now` is the present.
    private static func english(_ text: String, now: Date) -> SpokenDate? {
        guard text.contains(where: { $0.isASCII && $0.isLetter }), abs(now.timeIntervalSinceNow) < 120,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let date = match.date, let range = Range(match.range, in: text) else { return nil }
        let said = text[range].lowercased()
        let hasTime = said.contains(":") || ["am", "pm", "noon", "morning", "afternoon", "evening", "tonight", "o'clock", "midnight"]
            .contains(where: said.contains)
        return SpokenDate(date: hasTime ? date : Calendar.current.startOfDay(for: date), hasTime: hasTime, isApproximate: false)
    }

    private static func weekdayIndex(_ word: String) -> Int {
        switch word {
        case "一", "1": 1
        case "二", "2": 2
        case "三", "3": 3
        case "四", "4": 4
        case "五", "5": 5
        case "六", "6": 6
        default: 7
        }
    }

    // MARK: Time

    private static func time(in words: String) -> (Int, Int)? {
        if let match = words.firstMatch(of: #/(\d{1,2})[:：](\d{2})/#), let hour = Int(match.1), let minute = Int(match.2),
           hour < 24, minute < 60 {
            return (adjusted(hour, period: period(in: words)), minute)
        }
        guard let match = words.firstMatch(of: #/(\d{1,2})点(?:(半)|(一刻)|(三刻)|(\d{1,2})分?)?/#), let hour = Int(match.1), hour <= 24 else {
            return nil
        }
        let minute = match.2 != nil ? 30 : match.3 != nil ? 15 : match.4 != nil ? 45 : match.5.flatMap { Int($0) } ?? 0
        return (adjusted(hour, period: period(in: words)), min(minute, 59))
    }

    private enum Period { case morning, noon, afternoon, evening, none }

    private static func period(in words: String) -> Period {
        if ["凌晨", "早上", "上午", "早晨", "明早", "今早"].contains(where: words.contains) { return .morning }
        if words.contains("中午") { return .noon }
        if words.contains("下午") || words.contains("傍晚") { return .afternoon }
        if ["晚上", "今晚", "明晚", "夜里", "晚"].contains(where: words.contains) { return .evening }
        return .none
    }

    /// 下午三点 → 15; a bare 三点 means the afternoon (nobody books 3 am); 中午一点 → 13.
    private static func adjusted(_ hour: Int, period: Period) -> Int {
        switch period {
        case .morning: return hour == 12 ? 0 : hour
        case .noon: return hour < 11 ? hour + 12 : hour
        case .afternoon, .evening: return hour < 12 ? hour + 12 : hour
        case .none: return (1...6).contains(hour) ? hour + 12 : hour % 24
        }
    }

    // MARK: Numbers

    /// 三 → 3, 十五 → 15, 二十三 → 23, 两 → 2, so the patterns only deal with digits.
    static func normalizedNumbers(_ text: String) -> String {
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        var result = ""
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            var value = 0
            var current = 0
            for character in run {
                if character == "十" {
                    value += (current == 0 ? 1 : current) * 10
                    current = 0
                } else if let digit = digits[character] {
                    current = current * 10 + digit
                }
            }
            result += String(value + current)
            run = ""
        }
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            // Weekday names stay as words: 星期一, 周三, 礼拜天.
            let previous = index > 0 ? characters[index - 1] : " "
            let isWeekday = run.isEmpty && ["周", "期", "拜"].contains(previous)
            // 一 in 一下 / 一起 / 一刻 isn't a number to count with.
            let next = index + 1 < characters.count ? characters[index + 1] : " "
            let isWord = character == "一" && run.isEmpty && ["下", "起", "直", "定", "般", "刻"].contains(next)
            if !isWeekday, !isWord, digits[character] != nil || character == "十" {
                run.append(character)
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        return result
    }
}
