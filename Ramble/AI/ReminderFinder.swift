import Foundation

/// Finds the clauses in a tidied passage that ask for something to be done at a future time
/// (「下周三可以开始铺砖」「三个月后复查血脂」「合同下周五之前要签完」) and suggests a reminder for
/// each. On-device models only rewrite the text; this does the rest the same way every time.
nonisolated enum ReminderFinder {
    /// Words that make a clause something to do rather than something that happened.
    private static let actionCues = ["要", "得", "记得", "别忘", "需要", "可以", "去", "来", "交", "签", "还", "复查", "开始",
                                     "截止", "提醒", "办", "约", "参加", "开会", "带", "买", "做", "完成", "提交", "取", "送"]

    /// Time words as `SpokenDate` reads them (numbers already in digits), with 之前 and the like.
    private static let timeWords = #/(?:(?:\d{4}年|明年|今年|后年)?\d{1,2}月(?:\d{1,2}[日号])?|大后天|后天|明天|明日|明早|明晚|今天|今日|今晚|今早|(?:下下|下|这|本|上)?个?(?:周|星期|礼拜)[一二三四五六日天1-7]|(?:\d+|半)个?(?:天|日|周|星期|礼拜|月|年)(?:以后|之后|后)|过\d+天|(?:下个?月)?\d{1,2}[号日]|月底|月末|下个?月初|年底|年末|下个?月|(?:上午|下午|晚上|中午|早上|傍晚|凌晨)?\d{1,2}(?:点|[:：])(?:半|一刻|三刻|\d{1,2}分?)?|上午|下午|晚上|中午|早上)(?:之前|以前|前|左右)?/#

    private static let leadingWords = #/^(?:我们|我|你|他们|他|她|就|再来|再|还|然后|记得|别忘了|一定要|一定|准备|打算|在|的|，)+/#
    private static let reportedSpeech = #/^.{0,6}?(?:说|讲|通知|提醒)(?:了)?/#
    private static let modalWords = #/(?:需要|应该|可以|记得|得|要|再来|再)/#

    static func find(in text: String, now: Date = .now, calendar: Calendar = .current) -> [ReminderSuggestion] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        var found: [ReminderSuggestion] = []
        for clause in clauses(of: text) {
            guard let spoken = SpokenDate.resolve(clause, now: now, calendar: calendar) else { continue }
            // Ahead of now: tomorrow or later, or a time later today.
            let isAhead = spoken.date >= endOfToday || (spoken.hasTime && spoken.date > now)
            guard isAhead, actionCues.contains(where: clause.contains), let title = title(of: clause) else { continue }
            formatter.dateFormat = "yyyy-MM-dd"
            let day = formatter.string(from: spoken.date)
            formatter.dateFormat = "HH:mm"
            found.append(ReminderSuggestion(quote: clause, title: title, date: day, time: spoken.hasTime ? formatter.string(from: spoken.date) : ""))
        }
        return found
    }

    /// Clauses as they appear in the text, so a reminder's quote can be found and underlined.
    static func clauses(of text: String) -> [String] {
        text.split { "，,。.；;！!？?\n".contains($0) }
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 「下周三可以开始铺砖」→「开始铺砖」, 「他说合同下周五之前要签完」→「合同签完」.
    static func title(of clause: String) -> String? {
        var title = SpokenDate.normalizedNumbers(clause)
        title = title.replacing(timeWords, with: "")
        if let match = title.firstMatch(of: reportedSpeech), match.output.count < title.count - 1 {
            title = String(title[match.range.upperBound...])
        }
        title = title.replacing(leadingWords, with: "")
        title = title.replacing(modalWords, with: "")
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " ，,了吧啊呢哦。"))
        guard title.count >= 2 else { return nil }
        return String(title.prefix(20))
    }
}
