import Foundation
import Testing
@testable import Ramble

/// Cloud requests ask for as little "thinking" as each model allows, and Gemini isn't made
/// to write out every empty field.
struct CloudSpeedTests {
    private func body(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    @Test func geminiThinkingIsTurnedDown() throws {
        #expect(CloudClient.geminiThinkingConfig("gemini-3.8-flash")?["thinkingLevel"] as? String == "low")
        #expect(CloudClient.geminiThinkingConfig("models/gemini-3.5-flash-lite")?["thinkingLevel"] as? String == "minimal")
        #expect(CloudClient.geminiThinkingConfig("gemini-3.1-pro")?["thinkingLevel"] as? String == "low")
        #expect(CloudClient.geminiThinkingConfig("gemini-2.5-flash")?["thinkingBudget"] as? Int == 0)
        #expect(CloudClient.geminiThinkingConfig("gemini-2.5-pro")?["thinkingBudget"] as? Int == 128)
        #expect(CloudClient.geminiThinkingConfig("gemini-2.0-flash") == nil)

        let request = try CloudClient(provider: .gemini, apiKey: "k", model: "gemini-3.8-flash")
            .makeParseRequest(instructions: "sys", input: "x", schema: CaptureSchema.capture)
        let config = try #require(body(request)["generationConfig"] as? [String: Any])
        #expect((config["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String == "low")
    }

    @Test func openAIReasoningIsTurnedDown() throws {
        #expect(CloudClient.openAIReasoningEffort("gpt-6-astra") == "low")
        #expect(CloudClient.openAIReasoningEffort("gpt-5.6") == "none")
        #expect(CloudClient.openAIReasoningEffort("gpt-5-mini") == "minimal")
        #expect(CloudClient.openAIReasoningEffort("o4-mini") == "low")
        #expect(CloudClient.openAIReasoningEffort("gpt-4.1") == nil)

        let request = try CloudClient(provider: .openai, apiKey: "k", model: "gpt-6-astra")
            .makeParseRequest(instructions: "sys", input: "x", schema: CaptureSchema.capture)
        #expect((body(request)["reasoning"] as? [String: Any])?["effort"] as? String == "low")
        let old = try CloudClient(provider: .openai, apiKey: "k", model: "gpt-4.1")
            .makeParseRequest(instructions: "sys", input: "x", schema: CaptureSchema.capture)
        #expect(body(old)["reasoning"] == nil)
    }

    @Test func strongerThinkingIsOptional() throws {
        let saved = UserDefaults.standard.object(forKey: AISettings.thinkingKey)
        defer { UserDefaults.standard.set(saved, forKey: AISettings.thinkingKey) }
        UserDefaults.standard.removeObject(forKey: AISettings.thinkingKey)
        #expect(AISettings.thinkingSetting == .auto)
        UserDefaults.standard.set(ThinkingSetting.thorough.rawValue, forKey: AISettings.thinkingKey)
        #expect(AISettings.thinkingSetting == .thorough)

        #expect(CloudClient.geminiThinkingConfig("gemini-3.8-flash", thinking: .balanced)?["thinkingLevel"] as? String == "medium")
        #expect(CloudClient.geminiThinkingConfig("gemini-3.8-flash", thinking: .thorough)?["thinkingLevel"] as? String == "high")
        #expect(CloudClient.geminiThinkingConfig("gemini-3.5-flash-lite", thinking: .balanced)?["thinkingLevel"] as? String == "low")
        #expect(CloudClient.geminiThinkingConfig("gemini-2.5-flash", thinking: .thorough)?["thinkingBudget"] as? Int == 8_192)
        #expect(CloudClient.openAIReasoningEffort("gpt-6-astra", thinking: .thorough) == "high")
        #expect(CloudClient.openAIReasoningEffort("gpt-5.6", thinking: .balanced) == "low")
        #expect(CloudClient.openAIReasoningEffort("gpt-4.1", thinking: .thorough) == nil)
        #expect(CloudClient.anthropicEffort(.balanced) == "medium")

        let client = CloudClient(provider: .anthropic, apiKey: "k", model: "claude-opus-5-5", thinking: .thorough)
        let request = try client.makeParseRequest(instructions: "sys", input: "x", schema: CaptureSchema.capture)
        #expect((body(request)["output_config"] as? [String: Any])?["effort"] as? String == "high")
        #expect(request.timeoutInterval == 180)
        let fast = try CloudClient(provider: .anthropic, apiKey: "k", model: "claude-opus-5-5")
            .makeParseRequest(instructions: "sys", input: "x", schema: CaptureSchema.capture)
        #expect((body(fast)["output_config"] as? [String: Any])?["effort"] as? String == "low")
        #expect(fast.timeoutInterval == 90)
    }

    @Test func geminiOnlyRequiresTheEssentials() throws {
        let capture = CaptureSchema.capture.geminiSchema
        #expect(capture["required"] as? [String] == ["items"])
        let item = try #require((capture["properties"] as? [String: Any])?["items"] as? [String: Any])
        let itemSchema = try #require(item["items"] as? [String: Any])
        #expect(itemSchema["required"] as? [String] == ["type", "title"])
        #expect((itemSchema["propertyOrdering"] as? [String])?.count == 24)

        // Strict JSON Schema (Claude, OpenAI) still lists every property.
        let strict = try #require(((CaptureSchema.capture.jsonSchema["properties"] as? [String: Any])?["items"] as? [String: Any])?["items"] as? [String: Any])
        #expect((strict["required"] as? [String])?.count == 24)

        let organizer = NoteOrganizer.schema.geminiSchema
        #expect(organizer["required"] as? [String] == ["cleanedText"])
    }

    @Test func missingOptionalFieldsDecodeAsEmpty() throws {
        let capture = try CloudClient.decode(ParsedCapture.self, from: #"{"items":[{"type":"expense","title":"午餐","amount":"35"}]}"#)
        let item = try #require(capture.items.first)
        #expect(item.amount == "35")
        #expect(item.date.isEmpty)
        #expect(item.repeatFrequency == "none")
        #expect(item.repeatInterval == 1)
        #expect(capture.fillerPhrases.isEmpty)
    }
}
