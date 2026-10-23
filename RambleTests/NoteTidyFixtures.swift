import Foundation
import Testing
@testable import Ramble

/// What Qwen3 4B wrote for real dictation on a Mac (same prompts and grammar as the phone),
/// and what the checks must make of it.
struct NoteTidyFixtures {
    private static let good: [(String, String)] = [
        ("在语音输出的内容的地方设计一个这个X之类的就是可以一键删除内容的功能尤其是那个重说的时候这个有可能这个东西之前说的就不用了还需要一个一个删不方便设计一个一键删除的东西",
         "在语音输出的内容处设计一个X之类的按钮，可以一键删除内容，尤其是重说的时候，之前说的那些内容可能就不用了，需要一个一键删除的功能，不用一个一个删。"),
        ("呃，有的时候就是嗯过这个呃过很长时间，比如说今天第一次打开这个APP呃在上滑退出的时候上滑的时候这个动画会有些卡这是不是APP的一个bug",
         "有时候过很长时间后，第一次打开这个APP，在上滑退出时，上滑的动画会有些卡，这是不是APP的一个bug？"),
        ("嗯那个今天师傅来看了一下，就是说墙面要等干透才能刷漆，大概要一周。然后下周三可以开始铺砖，呃，记得提前把瓷砖搬上楼",
         "今天师傅来看了一下，墙面要等干透才能刷漆，大概要一周。下周三可以开始铺砖，记得提前把瓷砖搬上楼。"),
        ("呃就是体检报告出来了，然后那个甘油三酯有点高，二点一，医生说嗯注意饮食，三个月以后再来复查一下血脂",
         "体检报告出来了，甘油三酯有点高，是二点一，医生说注意饮食，三个月后复查血脂。"),
        ("呃我今天就是跟那个王经理开会然后他说那个合同下周五之前要签完然后预算是十二万就是不能超了",
         "我今天跟王经理开会，他说合同下周五之前要签完，预算是十二万，不能超。"),
        ("就是我觉得那个首页的字有点小然后嗯老年人看不清楚可能要调大一点",
         "我觉得首页的字有点小，老年人看不清楚，可能要调大一点。"),
    ]

    @Test func goodRewritesPass() {
        for (said, written) in Self.good {
            #expect(NoteOrganizer.isFaithful(written, to: said, style: .fluent), "\(written)")
        }
    }

    /// The failures seen with the earlier brief.
    @Test func badRewritesFail() {
        let (said, _) = Self.good[0]
        // Copied back verbatim, no punctuation.
        #expect(!NoteOrganizer.isFaithful(said, to: said, style: .fluent))
        // Narrated, with details dropped.
        #expect(!NoteOrganizer.isFaithful("用户反映，首次打开APP时，在上滑退出的动画过程中会出现卡顿现象，怀疑是APP的bug。",
                                          to: Self.good[1].0, style: .fluent))
        // English slipped in.
        #expect(!NoteOrganizer.isFaithful("我今天跟王经理开会，他 said 合同下周五之前要签完，预算是十二万，不能超。",
                                          to: Self.good[4].0, style: .fluent))
        // A clause gone.
        #expect(!NoteOrganizer.isFaithful("墙面要等干透才能刷漆，大概要一周。下周三可以开始铺砖，记得提前把瓷砖搬上楼。",
                                          to: Self.good[2].0, style: .fluent))
    }

    @Test func remindersComeFromTheTidiedText() {
        let now = DraftParsing.date("2026-10-14", time: "19:40")!
        let titles = Self.good.flatMap { ReminderFinder.find(in: $0.1, now: now).map(\.title) }
        #expect(titles == ["开始铺砖", "复查血脂", "合同签完"])
    }
}
