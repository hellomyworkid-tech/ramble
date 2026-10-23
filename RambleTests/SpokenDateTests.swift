import Foundation
import Testing
@testable import Ramble

struct SpokenDateTests {
    /// Tuesday 2026-10-13, 12:30.
    private let now = DraftParsing.date("2026-10-13", time: "12:30")!

    private func day(_ text: String) -> String? {
        SpokenDate.resolve(text, now: now).map { result in
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: result.date)
            let day = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
            return result.hasTime ? day + String(format: " %02d:%02d", parts.hour!, parts.minute!) : day
        }
    }

    @Test(arguments: [
        ("今天", "2026-10-13"), ("明天", "2026-10-14"), ("后天", "2026-10-15"), ("大后天", "2026-10-16"), ("昨天", "2026-10-12"),
        ("下周三", "2026-10-21"), ("下星期一", "2026-10-19"), ("下个礼拜天", "2026-10-25"), ("这周五", "2026-10-16"),
        ("本周一", "2026-10-12"), ("周二", "2026-10-13"), ("周一", "2026-10-19"), ("下下周三", "2026-10-28"),
        ("三天后", "2026-10-16"), ("两周以后", "2026-10-27"), ("三个月以后", "2027-01-13"), ("半个月后", "2026-10-28"),
        ("一年后", "2027-10-13"), ("过十天", "2026-10-23"),
        ("月底前", "2026-10-31"), ("下个月初", "2026-11-01"), ("下个月十五号", "2026-11-15"), ("二十号", "2026-10-20"),
        ("十号", "2026-11-10"), ("12月25日", "2026-12-25"), ("三月一号", "2027-03-01"), ("2027年2月28日", "2027-02-28"),
        ("年底", "2026-12-31"),
    ])
    func days(_ text: String, _ expected: String) {
        #expect(day(text) == expected)
    }

    @Test(arguments: [
        ("下周四下午三点", "2026-10-22 15:00"), ("明天上午十点半", "2026-10-14 10:30"), ("今晚八点", "2026-10-13 20:00"),
        ("明天三点", "2026-10-14 15:00"), ("后天早上7点一刻", "2026-10-15 07:15"), ("周五 14:30", "2026-10-16 14:30"),
        ("明天中午十二点", "2026-10-14 12:00"),
    ])
    func daysWithTimes(_ text: String, _ expected: String) {
        #expect(day(text) == expected)
    }

    @Test func monthOnlyIsApproximate() throws {
        let result = try #require(SpokenDate.resolve("明年三月", now: now))
        #expect(result.isApproximate)
        #expect(day("明年三月") == "2027-03-01")
    }

    @Test(arguments: ["校服钱两百五要交", "", "记得提前把瓷砖搬上楼", "一下"])
    func nonDatesGiveNothing(_ text: String) {
        #expect(SpokenDate.resolve(text, now: now) == nil)
    }

    @Test func chineseNumbers() {
        #expect(SpokenDate.normalizedNumbers("二十三号三点半") == "23号3点半")
        #expect(SpokenDate.normalizedNumbers("十五天后") == "15天后")
        #expect(SpokenDate.normalizedNumbers("两千一百八") == "2千1百8")
        #expect(SpokenDate.normalizedNumbers("星期一来看一下") == "星期一来看一下")
    }
}

struct OnDevicePolishTests {
    private let now = DraftParsing.date("2026-10-13", time: "12:30")!

    /// What Qwen3 4B actually returned for this passage (dates off, a clause dropped).
    @Test func modelDatesAreReplacedAndDroppedClausesRestored() {
        let original = "嗯那个今天师傅来看了一下，就是说墙面要等干透才能刷漆，大概要一周。然后下周三可以开始铺砖，呃，记得提前把瓷砖搬上楼"
        let raw = OnDeviceOrganizedNote(
            cleanedText: "墙面要等干透才能刷漆，大概要一周。下周三可以开始铺砖。记得提前把瓷砖搬上楼。",
            title: "",
            reminders: [
                OnDeviceReminderSuggestion(quote: "下周三可以开始铺砖。", title: "铺砖", when: "下周三", date: "2026-11-03", time: ""),
                OnDeviceReminderSuggestion(quote: "记得提前把瓷砖搬上楼。", title: "搬瓷砖", when: "记得提前把瓷砖搬上楼", date: "2026-10-13", time: ""),
            ])
        let polished = NoteOrganizer.polished(raw, original: original, now: now)
        #expect(polished.cleanedText.hasPrefix("今天师傅来看了一下，"))
        #expect(!polished.cleanedText.contains("嗯"))
        #expect(polished.reminders.map(\.date) == ["2026-10-21"])
        #expect(polished.reminders.first?.title == "铺砖")
    }

    @Test func faithfulTidyingIsKept() {
        let original = "呃就是体检报告出来了，然后那个甘油三酯有点高，二点一，医生说嗯注意饮食，三个月以后再来复查一下血脂"
        let tidy = "体检报告出来了，甘油三酯有点高，二点一，医生说注意饮食，三个月以后再来复查一下血脂。"
        #expect(NoteOrganizer.coverage(of: tidy, against: original) >= 0.85)
        let raw = OnDeviceOrganizedNote(cleanedText: tidy, title: "",
                                        reminders: [OnDeviceReminderSuggestion(quote: "三个月以后再来复查一下血脂", title: "复查血脂", when: "三个月以后", date: "2026-10-13", time: "")])
        let polished = NoteOrganizer.polished(raw, original: original, now: now)
        #expect(polished.cleanedText == tidy)
        #expect(polished.reminders.first?.date == "2027-01-13")
    }

    /// What Qwen3 1.7B returned: the passage with the "Now" line from its instructions in front.
    @Test func echoedInstructionsAreDropped() {
        let original = "嗯那个今天师傅来看了一下，就是说墙面要等干透才能刷漆，大概要一周。然后下周三可以开始铺砖，呃，记得提前把瓷砖搬上楼"
        let raw = OnDeviceOrganizedNote(
            cleanedText: "#2026-10-13 14:44, Tuesday (Asia/Shanghai) 今天师傅来看了一下，墙面要等干透才能刷漆，大概要一周。下周三可以开始铺砖，记得提前把瓷砖搬上楼",
            title: "", reminders: [])
        let polished = NoteOrganizer.polished(raw, original: original, now: now)
        #expect(polished.cleanedText.hasPrefix("今天师傅来看了一下"))
        #expect(!polished.cleanedText.contains("Tuesday"))
    }

    @Test func reminderTitlesLoseTheirLabel() {
        #expect(NoteOrganizer.reminderTitle("提醒：下周三可以开始铺砖") == "下周三可以开始铺砖")
        #expect(NoteOrganizer.reminderTitle("记得提前把瓷砖搬上楼") == "提前把瓷砖搬上楼")
        #expect(NoteOrganizer.reminderTitle("复查血脂") == "复查血脂")
        #expect(NoteOrganizer.reminderTitle("提醒") == "提醒")
        let raw = OnDeviceOrganizedNote(cleanedText: "下周三可以开始铺砖", title: "",
                                        reminders: [OnDeviceReminderSuggestion(quote: "下周三可以开始铺砖", title: "提醒：下周三可以开始铺砖", when: "下周三", date: "", time: "")])
        #expect(NoteOrganizer.polished(raw, original: "下周三可以开始铺砖", now: now).reminders.first?.title == "下周三可以开始铺砖")
    }

    @Test func captureItemsTakeTheResolvedDate() {
        var item = ParsedItem()
        item.date = "2026-10-15"
        item.apply(SpokenDate.resolve("下周四下午三点", now: now)!)
        #expect(item.date == "2026-10-22")
        item.time = ""
        item.apply(SpokenDate.resolve("明年三月", now: now)!)
        #expect(item.date == "2027-03-01")
        #expect(item.dateIsApproximate)
        #expect(item.uncertainFields == ["date"])
    }
}
