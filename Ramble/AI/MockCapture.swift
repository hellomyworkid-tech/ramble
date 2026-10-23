#if DEBUG
import Foundation

/// Canned result for the `-mockAI` launch argument: lets the review screen be
/// exercised in the simulator without a model or an API key.
nonisolated enum MockCapture {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-mockAI")
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func nextWednesday(after now: Date, calendar: Calendar = .current) -> Date {
        let thisWeek = calendar.nextDate(after: now, matching: DateComponents(weekday: 4), matchingPolicy: .nextTime) ?? now
        return calendar.date(byAdding: .day, value: 7, to: thisWeek) ?? thisWeek
    }

    /// The renovation scenario: a note, a reminder tied to one of its sentences, and an expense.
    private static func renovation(now: Date) -> ParsedCapture {
        let sentence = "师傅说水泥要养护 7 天，下周三可以铺砖。"
        var note = ParsedItem()
        note.type = "note"; note.title = "装修记录"; note.note = sentence + "\n今天买瓷砖花了 3,200 元。"
        var task = ParsedItem()
        task.type = "task"; task.title = "铺砖"; task.date = day(nextWednesday(after: now)); task.quote = sentence
        var tiles = ParsedItem()
        tiles.type = "expense"; tiles.title = "瓷砖"; tiles.amount = "3200"; tiles.category = "居住"; tiles.date = day(now)
        return ParsedCapture(items: [note, task, tiles], fillerPhrases: ["那边", "然后"], followUpQuestion: "")
    }

    /// Reading a file: a checkup report, a warranty card, or anything else.
    static func document(for text: String, noteTitle: String?, now: Date) -> ParsedCapture {
        let calendar = Calendar.current
        var note = ParsedItem()
        note.type = "note"
        if text.contains("体检") || text.contains("甘油三酯") || text.contains("血脂") {
            let advice = "· 医生建议：低脂低嘌呤饮食，适量运动；3 个月后复查血脂、尿酸。"
            note.title = noteTitle ?? "体检复查"
            note.note = """
            2026 年度健康体检报告（和睦体检中心，2026-09-12）
            · 甘油三酯 2.10 mmol/L ↑（参考 0.45–1.70）
            · 低密度脂蛋白胆固醇 3.62 mmol/L ↑（参考 0–3.37）
            · 尿酸 452 μmol/L ↑（参考 208–428）
            · 其余项目在参考范围内。
            \(advice)
            """
            var recheck = ParsedItem()
            recheck.type = "task"; recheck.title = "复查血脂、尿酸"; recheck.listName = "健康"; recheck.quote = advice
            let reportDay = DraftParsing.date("2026-09-12") ?? now
            recheck.date = day(calendar.date(byAdding: .month, value: 3, to: reportDay) ?? now)
            return ParsedCapture(items: [note, recheck])
        }
        if text.contains("质保") || text.contains("保修") {
            note.title = noteTitle ?? "装修记录"
            note.note = """
            瓷砖质保单（2026-10-11 购买）
            · 型号：Ceramic 600x1200 灰色哑光，42 箱
            · 质保期 10 年，至 2036-10-11
            · 售后电话：400-820-1234
            """
            var warranty = ParsedItem()
            warranty.type = "expiry"; warranty.title = "瓷砖质保"; warranty.expiryKind = "warranty"
            warranty.date = "2036-10-11"; warranty.reminderDaysBefore = [30, 7, 0]
            return ParsedCapture(items: [note, warranty])
        }
        note.title = noteTitle ?? "资料"
        let excerpt = text.split(separator: "\n").prefix(4).map { "· " + $0 }.joined(separator: "\n")
        note.note = "文件摘要\n" + (excerpt.isEmpty ? "· 没有认出文字" : excerpt)
        return ParsedCapture(items: [note])
    }

    static func organizedNote(for input: String, now: Date) -> OrganizedNote {
        var cleaned = input
        for filler in ["嗯…", "嗯", "啊", "那个", "然后", "就是"] {
            cleaned = cleaned.replacingOccurrences(of: filler, with: "")
        }
        cleaned = cleaned.trimmed
        var reminders: [ReminderSuggestion] = []
        if let sentence = Sentences.split(cleaned).first(where: { $0.contains("下周三") }) {
            reminders.append(ReminderSuggestion(quote: sentence, title: "铺砖", date: day(nextWednesday(after: now))))
        }
        return OrganizedNote(cleanedText: cleaned, title: "", reminders: reminders)
    }

    static func capture(for input: String, now: Date) -> ParsedCapture {
        if input.contains("装修") { return renovation(now: now) }
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let answered = input.contains("补充")

        var lunch = ParsedItem()
        lunch.type = "expense"; lunch.title = "午餐"; lunch.amount = "35"; lunch.category = "餐饮"
        lunch.account = "电子钱包"; lunch.date = formatter.string(from: now); lunch.time = "12:00"

        var card = ParsedItem()
        card.type = "bill"; card.title = "信用卡还款"; card.billKind = "creditCard"; card.account = "储蓄卡"
        card.amount = answered ? "2180" : "2000"
        card.amountIsApproximate = !answered
        card.uncertainFields = answered ? [] : ["amount"]
        card.date = formatter.string(from: Recurrence.firstMonthly(day: 15, onOrAfter: now, calendar: calendar))
        card.repeatFrequency = "monthly"; card.repeatMonthDay = 15; card.reminderDaysBefore = [3, 0]

        var passport = ParsedItem()
        passport.type = "expiry"; passport.title = "护照"; passport.expiryKind = "document"
        let year = calendar.component(.year, from: now) + 1
        passport.date = answered ? "\(year)-03-12" : "\(year)-03-01"
        passport.dateIsApproximate = !answered
        passport.uncertainFields = answered ? [] : ["date"]

        return ParsedCapture(
            items: [lunch, card, passport],
            fillerPhrases: ["嗯…那个", "啊对，", "然后"],
            followUpQuestion: answered ? "" : "信用卡这期具体多少？护照是 3 月几号到期？"
        )
    }
}
#endif
