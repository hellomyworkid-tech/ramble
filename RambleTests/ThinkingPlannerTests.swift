import Foundation
import Testing
@testable import Ramble

struct ThinkingPlannerTests {
    private func start(_ task: AITask) -> AIThinking {
        ThinkingPlanner.plan(for: task, setting: .auto).start
    }

    @Test func aSentenceOrTwoIsAlwaysFast() {
        #expect(start(.capture("中午吃饭花了三十五")) == .fast)
        #expect(start(.capture("信用卡十五号要还两千一百八，护照明年三月到期")) == .fast)
        // Lots of filler but little said: measured after the filler is gone.
        #expect(start(.capture("嗯那个，呃，就是，然后那个，嗯，中午那个吃饭，嗯，花了三十五，呃就是这样")) == .fast)
        // Even a self-correction stays fast when it's short.
        #expect(start(.capture("三十，不对，四十")) == .fast)
        #expect(ThinkingPlanner.plan(for: .capture("午饭35"), setting: .auto).cap == .balanced)
    }

    @Test func longOrTangledCapturesThinkABit() {
        let long = String(repeating: "今天去超市买了牛奶面包和鸡蛋一共花了八十六块，", count: 6)
        #expect(start(.capture(long)) == .balanced)
        let tangled = "房租是三千五，不对，应该是三千八，下个月五号交，然后物业费二百四十，水电大概三百，信用卡还两千一"
        #expect(start(.capture(tangled)) == .balanced)
        // Never more than balanced for a capture.
        #expect(ThinkingPlanner.plan(for: .capture(long), setting: .auto).cap == .balanced)
    }

    @Test func notesThinkOnlyWhenLong() {
        #expect(start(.organize("今天师傅来看了，下周三可以铺砖。")) == .fast)
        #expect(start(.organize(String(repeating: "今天装修师傅来看了水电，说墙面要等干透才能刷漆。", count: 10))) == .balanced)
    }

    @Test func documentsScaleWithSize() {
        #expect(start(.document(characters: 300, files: 1, pages: 1, originals: false)) == .fast)
        #expect(start(.document(characters: 1_500, files: 1, pages: 2, originals: false)) == .balanced)
        #expect(start(.document(characters: 1_500, files: 1, pages: 2, originals: true)) == .balanced)
        #expect(start(.document(characters: 20_000, files: 1, pages: 12, originals: false)) == .thorough)
        #expect(ThinkingPlanner.plan(for: .document(characters: 1_500, files: 1, pages: 2, originals: false), setting: .auto).cap == .thorough)
    }

    @Test func aFixedSettingIsObeyed() {
        let long = String(repeating: "很长的一段话，", count: 40)
        #expect(ThinkingPlanner.plan(for: .capture(long), setting: .fast) == .init(start: .fast, cap: .fast))
        #expect(ThinkingPlanner.plan(for: .capture("午饭35"), setting: .thorough) == .init(start: .thorough, cap: .thorough))
    }
}

struct ThinkingEscalationTests {
    private let client = CloudClient(provider: .gemini, apiKey: "k", model: "gemini-3.8-flash")

    /// Records the level of each attempt and answers from a script.
    private actor Script {
        var levels: [AIThinking] = []
        func record(_ level: AIThinking) { levels.append(level) }
    }

    @Test func aGoodFastAnswerIsNotRetried() async throws {
        let script = Script()
        let (answer, level) = try await ThinkingPlanner.run(.init(start: .fast, cap: .balanced), client: client,
                                                            isUsable: { $0 == "ok" }) { client in
            await script.record(client.thinking)
            return "ok"
        }
        #expect(answer == "ok")
        #expect(level == .fast)
        #expect(await script.levels == [.fast])
    }

    @Test func aBadFastAnswerIsRetriedOneLevelUp() async throws {
        let script = Script()
        let (answer, level) = try await ThinkingPlanner.run(.init(start: .fast, cap: .balanced), client: client,
                                                            isUsable: { $0 == "ok" }) { client in
            await script.record(client.thinking)
            return client.thinking == .fast ? "garbled" : "ok"
        }
        #expect(answer == "ok")
        #expect(level == .balanced)
        #expect(await script.levels == [.fast, .balanced])
    }

    @Test func anUnreadableAnswerIsRetriedToo() async throws {
        let (answer, level) = try await ThinkingPlanner.run(.init(start: .fast, cap: .balanced), client: client,
                                                            isUsable: { _ in true }) { client in
            if client.thinking == .fast { throw AIError.badResponse("JSON") }
            return "ok"
        }
        #expect(answer == "ok")
        #expect(level == .balanced)
    }

    @Test func noRetryPastTheCapOrForOtherErrors() async throws {
        let script = Script()
        let (answer, _) = try await ThinkingPlanner.run(.init(start: .fast, cap: .fast), client: client,
                                                        isUsable: { $0 == "ok" }) { client in
            await script.record(client.thinking)
            return "garbled"
        }
        #expect(answer == "garbled")
        #expect(await script.levels == [.fast])

        await #expect(throws: AIError.self) {
            _ = try await ThinkingPlanner.run(.init(start: .fast, cap: .balanced), client: client,
                                              isUsable: { (_: String) in true }) { _ in throw AIError.network("offline") }
        }
    }

    @Test func aRetryThatDoesNoBetterKeepsTheFirstAnswer() async throws {
        let (answer, level) = try await ThinkingPlanner.run(.init(start: .fast, cap: .balanced), client: client,
                                                            isUsable: { $0 == "ok" }) { client in
            client.thinking == .fast ? "first" : "second"
        }
        #expect(answer == "first")
        #expect(level == .fast)
    }
}
