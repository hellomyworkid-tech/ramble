import Foundation

/// Chinese numerals as digits, so a rewrite that turns 「两千一百八」 into 「2180」 still counts as
/// keeping the number.
nonisolated enum ChineseNumerals {
    private static let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
                                                   "六": 6, "七": 7, "八": 8, "九": 9]
    private static let units: [Character: Int] = ["十": 10, "百": 100, "千": 1000, "万": 10_000]

    /// 两千一百八 → 2180, 一百二 → 120, 三千二 → 3200, 一万二 → 12000, 二点一 → 2.1, 二零二六 → 2026.
    /// 一 in words (一下, 一起, 星期一, 有一点) stays as it is.
    static func normalize(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard isNumeral(character), !isWord(at: index, in: characters) else {
                result.append(character)
                index += 1
                continue
            }
            var end = index
            while end < characters.count, isNumeral(characters[end]) { end += 1 }
            // 点 followed by a digit is a decimal point: 二点一.
            var fraction = ""
            if end + 1 < characters.count, characters[end] == "点", let first = digits[characters[end + 1]] {
                fraction = String(first)
                var cursor = end + 2
                while cursor < characters.count, let digit = digits[characters[cursor]] {
                    fraction += String(digit)
                    cursor += 1
                }
                result += value(of: Array(characters[index..<end])) + "." + fraction
                index = cursor
                continue
            }
            result += value(of: Array(characters[index..<end]))
            index = end
        }
        return result
    }

    /// The numbers worth checking in a rewrite: 10 or more, or with a decimal point. Single digits
    /// are left out because they are so often words (第一次 → 首次, 一点 → 有点).
    static func significantNumbers(in text: String) -> Set<String> {
        let found = normalize(text).matches(of: #/\d+(?:\.\d+)?/#).map { String($0.output) }
        return Set(found.compactMap { raw -> String? in
            guard let number = Decimal(string: raw) else { return nil }
            return number >= 10 || raw.contains(".") ? "\(number)" : nil
        })
    }

    private static func isNumeral(_ character: Character) -> Bool {
        digits[character] != nil || units[character] != nil
    }

    /// 一下, 一起, 一直, 一定, 一般, 一刻, 一些, 一样, 一切 and 有一点 are words; weekdays are names.
    private static func isWord(at index: Int, in characters: [Character]) -> Bool {
        let previous = index > 0 ? characters[index - 1] : " "
        if ["周", "期", "拜"].contains(previous) { return true }
        guard characters[index] == "一" else { return false }
        let next = index + 1 < characters.count ? characters[index + 1] : " "
        if ["下", "起", "直", "定", "般", "刻", "些", "样", "切", "边", "会"].contains(next) { return true }
        // 有一点 / 一点儿: a little, not one o'clock.
        return next == "点" && (previous == "有" || (index + 2 < characters.count && characters[index + 2] == "儿"))
    }

    /// One run of numerals as an integer string.
    private static func value(of run: [Character]) -> String {
        // All plain digits (二零二六): read them one by one.
        if run.allSatisfy({ digits[$0] != nil }) {
            return run.map { String(digits[$0]!) }.joined()
        }
        var total = 0
        var section = 0
        var current = 0
        var lastUnit = 1
        var afterZero = false
        for character in run {
            if let digit = digits[character] {
                if digit == 0 { afterZero = true }
                current = digit
            } else if let unit = units[character] {
                if unit == 10_000 {
                    total += (section + current) * unit
                    section = 0
                } else {
                    section += (current == 0 && unit == 10 ? 1 : current) * unit
                }
                current = 0
                lastUnit = unit
                afterZero = false
            }
        }
        // 一百二 is 120 and 三千二 is 3200: a last digit right after a unit counts in the next unit down.
        if current > 0, !afterZero, lastUnit >= 100, let lastCharacter = run.last, digits[lastCharacter] != nil,
           run.count >= 2, units[run[run.count - 2]] != nil {
            current *= lastUnit / 10
        }
        return String(total + section + current)
    }
}
