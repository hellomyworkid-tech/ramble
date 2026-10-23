import Foundation

extension Decimal {
    /// "¥82,000.00", not "CN¥82,000.00": the short symbol for the person's own currency,
    /// whatever the phone's region; other currencies keep the form that tells them apart ("US$12.00").
    nonisolated func money(_ currencyCode: String, wholeNumbers: Bool = false) -> String {
        let base = UserDefaults.standard.string(forKey: "baseCurrency") ?? "CNY"
        var style = Decimal.FormatStyle.Currency(code: currencyCode)
        if currencyCode == base { style = style.presentation(.narrow) }
        if wholeNumbers { style = style.precision(.fractionLength(0)) }
        return formatted(style)
    }

    /// Parses user input like "35", "1,280.5" or "35.00" in the current locale.
    nonisolated init?(userInput text: String, locale: Locale = .current) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: locale.groupingSeparator ?? ",", with: "")
        guard !trimmed.isEmpty, let value = Decimal(string: trimmed, locale: locale) ?? Decimal(string: trimmed) else {
            return nil
        }
        self = value
    }

    /// Plain text for an input field: no grouping, no currency symbol.
    nonisolated var inputText: String {
        formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
    }

    nonisolated var doubleValue: Double { NSDecimalNumber(decimal: self).doubleValue }
}

extension String {
    nonisolated var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

nonisolated enum DayText {
    /// Whole days from today to `date` (negative = past).
    static func daysUntil(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// "今天", "明天", "4 天后", "逾期 2 天"
    static func countdown(to date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let days = daysUntil(date, now: now, calendar: calendar)
        switch days {
        case 0: return String(localized: "今天")
        case 1: return String(localized: "明天")
        case 2: return String(localized: "后天")
        case let d where d > 0: return String(localized: "\(d) 天后")
        default: return String(localized: "逾期 \(-days) 天")
        }
    }

    /// "今天 18:00", "明天", "10月20日", "2027年3月12日"
    static func due(_ date: Date, hasTime: Bool, now: Date = .now, calendar: Calendar = .current) -> String {
        var text: String
        if calendar.isDateInToday(date) {
            text = String(localized: "今天")
        } else if calendar.isDateInTomorrow(date) {
            text = String(localized: "明天")
        } else if calendar.isDateInYesterday(date) {
            text = String(localized: "昨天")
        } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            text = date.formatted(.dateTime.month().day())
        } else {
            text = date.formatted(.dateTime.year().month().day())
        }
        if hasTime {
            text += " " + date.formatted(date: .omitted, time: .shortened)
        }
        return text
    }

    /// "10月15日 周四"
    static func dayWithWeekday(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().weekday(.abbreviated))
    }
}

extension Date {
    nonisolated func startOfMonth(calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .month, for: self)?.start ?? self
    }

    nonisolated func monthInterval(calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .month, for: self) ?? DateInterval(start: self, duration: 0)
    }
}

extension DateInterval {
    /// start ≤ date < end. `contains` is closed at the end, which double-counts
    /// a record at exactly midnight on the first day of the next period.
    nonisolated func holds(_ date: Date) -> Bool {
        date >= start && date < end
    }
}

/// Names of screens whose Chinese is also a row label, kept apart so English can say
/// "Accounts" for the screen and "Account" for the row.
nonisolated enum ScreenName {
    static let accounts = LocalizedStringResource("screen.accounts", defaultValue: "账户")
    static let categories = LocalizedStringResource("screen.categories", defaultValue: "分类")
    static let budgets = LocalizedStringResource("screen.budgets", defaultValue: "预算")
}

nonisolated enum AppLanguage {
    /// The language the app's screens are shown in: Chinese, or English for everyone else.
    static var isChinese: Bool {
        (Bundle.main.preferredLocalizations.first ?? "zh-Hans").hasPrefix("zh")
    }

    /// For AI instructions: "Chinese" or "English".
    static var name: String { isChinese ? "Chinese" : "English" }
}

nonisolated enum Punctuation {
    /// Dictation added to what was already there, with a break between the two when needed:
    /// 「，」 after Chinese, ", " after anything else.
    static func joining(_ base: String, _ addition: String) -> String {
        guard !base.isEmpty, !addition.isEmpty, !(base.last?.isPunctuation ?? true) else { return base + addition }
        let isChinese = base.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        return base + (isChinese ? "，" : ", ") + addition
    }

    /// Whether the text is mostly written in Chinese, for picking the language of AI replies.
    static func isMostlyChinese(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return Locale.current.language.languageCode == .chinese }
        let han = letters.filter { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
        return Double(han.count) / Double(letters.count) >= 0.3
    }
}
