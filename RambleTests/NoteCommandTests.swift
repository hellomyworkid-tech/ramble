import Foundation
import Testing
@testable import Ramble

struct NoteCommandTests {
    @Test(arguments: [
        ("本条是测试内容给本条标记一下重点。", "本条是测试内容。"),
        ("下周三铺砖，把这条标为重点", "下周三铺砖。"),
        ("划重点：体检报告周五出来", "：体检报告周五出来"),
        ("甘油三酯2.1偏高，帮我标记重点吧", "甘油三酯2.1偏高。"),
        ("护照明年三月到期，加个星标", "护照明年三月到期。"),
        ("设为重点，孩子周五要交校服钱", "孩子周五要交校服钱"),
    ])
    func commandsAreTakenOutAndCarriedOut(_ input: String, _ expected: String) {
        let result = NoteCommands.extract(input)
        #expect(result.markAsKeyPoint, "\(input)")
        #expect(result.text == expected, "\(input) → \(result.text)")
    }

    @Test func emphasisMarksButKeepsTheWords() {
        let result = NoteCommands.extract("这件事很重要，月底前一定要续签合同")
        #expect(result.markAsKeyPoint)
        #expect(result.text == "这件事很重要，月底前一定要续签合同")
    }

    @Test func ordinaryTextIsLeftAlone() {
        for text in ["今天师傅来看了一下，下周三铺砖", "重点是要先做防水", "他说这个不重要", "标记笔和尺子要买"] {
            let result = NoteCommands.extract(text)
            #expect(!result.markAsKeyPoint, "\(text)")
            #expect(result.text == text)
        }
    }
}

struct ChineseNumeralTests {
    @Test(arguments: [
        ("两千一百八", "2180"), ("一百二", "120"), ("三千二", "3200"), ("一万二", "12000"), ("十五号", "15号"),
        ("二点一", "2.1"), ("二零二六年", "2026年"), ("一百零二", "102"), ("三十五块", "35块"), ("一万五千", "15000"),
        ("星期一", "星期一"), ("等一下", "等一下"), ("有一点高", "有一点高"), ("下午三点", "下午3点"),
    ])
    func converts(_ text: String, _ expected: String) {
        #expect(ChineseNumerals.normalize(text) == expected, "\(text)")
    }

    @Test func significantNumbersIgnoreWordLikeDigits() {
        #expect(ChineseNumerals.significantNumbers(in: "第一次花了两千一百八，甘油三酯二点一") == ["2180", "2.1"])
    }
}

struct FluentTidyTests {
    private let original = "嗯那个孩子学校，就是老师说呃下周一要交那个春游的钱，然后一百二，春游是下周五，就是周五去植物园"

    @Test func aGoodRewritePasses() {
        #expect(NoteOrganizer.isFaithful("孩子学校的老师说，下周五春游去植物园，春游的钱 120 元，下周一要交。", to: original, style: .fluent))
    }

    @Test func changedOrInventedNumbersFail() {
        #expect(!NoteOrganizer.isFaithful("孩子学校的老师说，下周五春游去植物园，春游的钱 150 元，下周一要交。", to: original, style: .fluent))
        #expect(!NoteOrganizer.isFaithful("2026-10-13 孩子学校的老师说，下周五春游去植物园，春游的钱一百二，下周一要交。", to: original, style: .fluent))
    }

    @Test func theUsersOwnExampleRewritesCleanly() {
        let said = "呃，有的时候就是嗯过这个呃过很长时间，比如说今天第一次打开这个APP呃在上滑退出的时候上滑的时候这个动画会有些卡这是不是APP的一个bug"
        let written = "有时候隔了很长时间再打开 App，比如今天第一次打开时，上滑退出的动画会有些卡。这是不是 App 的 bug？"
        #expect(NoteOrganizer.isFaithful(written, to: said, style: .fluent))
    }

    @Test func droppingAClauseFails() {
        let said = "嗯那个今天师傅来看了一下，就是说墙面要等干透才能刷漆，大概要一周。然后下周三可以开始铺砖，呃，记得提前把瓷砖搬上楼"
        #expect(!NoteOrganizer.isFaithful("墙面要等干透才能刷漆，大概要一周。下周三可以开始铺砖，记得提前把瓷砖搬上楼。", to: said, style: .fluent))
        #expect(NoteOrganizer.isFaithful("今天师傅来看过，墙面要等干透才能刷漆，大概要一周。下周三可以开始铺砖，记得提前把瓷砖搬上楼。", to: said, style: .fluent))
    }

    @Test func droppingMostOfItFails() {
        #expect(!NoteOrganizer.isFaithful("春游的钱一百二。", to: original, style: .fluent))
    }

    @Test func lightStyleKeepsTheOldStrictCheck() {
        #expect(!NoteOrganizer.isFaithful("孩子学校的老师说，下周五春游去植物园，春游的钱一百二，下周一要交。", to: original, style: .light))
    }

    @Test func instructionsFollowTheStyle() {
        let fluent = NoteOrganizer.instructions(noteTitle: "", now: .now, style: .fluent)
        #expect(fluent.contains("clear, natural written sentences") && fluent.contains("markAsKeyPoint"))
        #expect(NoteOrganizer.instructions(noteTitle: "", now: .now, style: .light).contains("never reword"))
    }
}
