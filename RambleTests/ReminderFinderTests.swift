import Foundation
import Testing
@testable import Ramble

struct ReminderFinderTests {
    /// Wednesday 14 October 2026, 19:40.
    private let now = DraftParsing.date("2026-10-14", time: "19:40")!

    @Test func futureStepsBecomeReminders() {
        let found = ReminderFinder.find(in: "今天师傅来看了一下，墙面要等干透才能刷漆，大概要一周。下周三可以开始铺砖，记得提前把瓷砖搬上楼。", now: now)
        #expect(found.map(\.title) == ["开始铺砖"])
        #expect(found.first?.date == "2026-10-21" && found.first?.quote == "下周三可以开始铺砖")

        let checkUp = ReminderFinder.find(in: "体检报告出来了，甘油三酯有点高，是二点一，医生说注意饮食，三个月后复查血脂。", now: now)
        #expect(checkUp.map(\.title) == ["复查血脂"] && checkUp.first?.date == "2027-01-14")

        let contract = ReminderFinder.find(in: "我今天跟王经理开会，他说合同下周五之前要签完，预算是十二万，不能超。", now: now)
        #expect(contract.map(\.title) == ["合同签完"] && contract.first?.date == "2026-10-23")

        #expect(ReminderFinder.find(in: "三个月以后再来复查血脂。", now: now).first?.title == "复查血脂")

        let timed = ReminderFinder.find(in: "明天下午三点要去医院复查血脂。", now: now)
        #expect(timed.first?.title == "去医院复查血脂" && timed.first?.time == "15:00")
    }

    @Test func pastEventsAndPlainStatementsAreLeftAlone() {
        #expect(ReminderFinder.find(in: "今天师傅来看了一下，昨天买了瓷砖。", now: now).isEmpty)
        #expect(ReminderFinder.find(in: "有时候过很长时间后，第一次打开这个APP，上滑的动画会有些卡。", now: now).isEmpty)
        #expect(ReminderFinder.find(in: "我觉得首页的字有点小，可能要调大一点。", now: now).isEmpty)
    }
}

struct QuoteAnchorTests {
    @Test func quotesFollowTheRewrite() {
        let text = "装修那边的师傅说，水泥要养护七天，下周三可以铺砖。今天买瓷砖花了三千二。"
        #expect(NoteOrganizer.anchor("下周三可以铺砖", in: text) == "下周三可以铺砖")
        #expect(NoteOrganizer.anchor("明天下午三点要去医院复查血脂", in: "明天下午三点去医院复查血脂，挂号费五十。") == "明天下午三点去医院复查血脂")
        #expect(NoteOrganizer.anchor("周五交报告", in: text).isEmpty)
    }
}
