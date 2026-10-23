import Foundation
import Testing
@testable import Ramble

/// Writes the exact instructions the app gives open models, for running them on a Mac.
/// Off by default; run with TEST_RUNNER_RAMBLE_DUMP_PROMPTS=<folder>.
struct PromptDumpTests {
    nonisolated static let folder = ProcessInfo.processInfo.environment["RAMBLE_DUMP_PROMPTS"]

    @Test(.enabled(if: folder != nil))
    func dump() throws {
        let folder = URL(filePath: try #require(Self.folder))
        let now = DraftParsing.date("2026-10-14", time: "19:40")!
        let context = CaptureContext(now: now, timeZone: .current, baseCurrency: "CNY",
                                     expenseCategories: ["餐饮", "交通", "购物", "居住", "娱乐", "医疗", "学习", "通讯", "人情", "旅行", "其他"],
                                     incomeCategories: ["工资", "奖金", "理财", "其他收入"],
                                     accounts: [("现金", "cash"), ("储蓄卡", "debitCard"), ("信用卡", "creditCard"), ("电子钱包", "eWallet")],
                                     existingNotes: ["装修记录", "家里常用信息", "体检复查"])
        try (context.compactInstructions + OpenCapture.examples).write(to: folder.appending(path: "capture.txt"), atomically: true, encoding: .utf8)
        for style in NoteTidyStyle.allCases {
            try NoteOrganizer.openInstructions(style).write(to: folder.appending(path: "tidy-\(style.rawValue)-app.txt"), atomically: true, encoding: .utf8)
            try NoteOrganizer.instructions(noteTitle: "随口记 app", now: now, style: style)
                .write(to: folder.appending(path: "organize-\(style.rawValue).txt"), atomically: true, encoding: .utf8)
        }
    }
}
