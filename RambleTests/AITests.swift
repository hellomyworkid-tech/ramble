import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import Ramble

struct SchemaTests {
    /// Strict mode on Claude and OpenAI rejects any object that isn't closed and fully required.
    @Test func jsonSchemaClosesEveryObject() {
        func check(_ node: [String: Any]) {
            if node["type"] as? String == "object" {
                let properties = node["properties"] as? [String: Any] ?? [:]
                #expect(node["additionalProperties"] as? Bool == false)
                #expect(Set(node["required"] as? [String] ?? []) == Set(properties.keys))
                properties.values.compactMap { $0 as? [String: Any] }.forEach(check)
            }
            if let items = node["items"] as? [String: Any] { check(items) }
        }
        check(CaptureSchema.capture.jsonSchema)
    }

    @Test func geminiSchemaUsesOpenAPITypes() {
        let schema = CaptureSchema.capture.geminiSchema
        #expect(schema["type"] as? String == "OBJECT")
        #expect(schema["additionalProperties"] == nil)
        let items = (schema["properties"] as? [String: Any])?["items"] as? [String: Any]
        #expect(items?["type"] as? String == "ARRAY")
        let type = ((items?["items"] as? [String: Any])?["properties"] as? [String: Any])?["type"] as? [String: Any]
        #expect(type?["enum"] as? [String] == CaptureSchema.itemTypes)
    }

    @Test func instructionsCarryContext() {
        let context = CaptureContext(now: Date(timeIntervalSince1970: 1_791_720_000), timeZone: TimeZone(identifier: "Asia/Shanghai")!,
                                     baseCurrency: "CNY", expenseCategories: ["餐饮", "交通"], incomeCategories: ["工资"],
                                     accounts: [("储蓄卡", "debitCard")])
        #expect(context.instructions.contains("2026-10-11"))
        #expect(context.instructions.contains("餐饮, 交通"))
        #expect(context.instructions.contains("储蓄卡 (debitCard)"))
    }
}

struct CloudClientTests {
    private func body(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    @Test func claudeRequestUsesStructuredOutputLowEffortAndFallbacks() throws {
        let request = try CloudClient(provider: .anthropic, apiKey: "sk-ant-test", model: "claude-opus-5-5")
            .makeParseRequest(instructions: "sys", input: "午饭35", schema: CaptureSchema.capture)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        let json = body(request)
        #expect(json["model"] as? String == "claude-opus-5-5")
        #expect(json["fallbacks"] as? String == "default")
        #expect(json["thinking"] == nil)
        let config = json["output_config"] as? [String: Any]
        #expect(config?["effort"] as? String == "low")
        #expect((config?["format"] as? [String: Any])?["type"] as? String == "json_schema")
    }

    @Test func haikuGetsNoServerFallback() throws {
        let request = try CloudClient(provider: .anthropic, apiKey: "k", model: "claude-haiku-5-5")
            .makeParseRequest(instructions: "sys", input: "x", schema: CaptureSchema.capture)
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
        #expect(body(request)["fallbacks"] == nil)
    }

    @Test func openAIRequestUsesStrictJSONSchema() throws {
        let request = try CloudClient(provider: .openai, apiKey: "sk-test", model: "gpt-6-astra")
            .makeParseRequest(instructions: "sys", input: "x", schema: CaptureSchema.capture)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let format = (body(request)["text"] as? [String: Any])?["format"] as? [String: Any]
        #expect(format?["type"] as? String == "json_schema")
        #expect(format?["strict"] as? Bool == true)
    }

    @Test func geminiKeyTravelsInHeaderNotURL() throws {
        let request = try CloudClient(provider: .gemini, apiKey: "AIza-test", model: "gemini-3.8-flash")
            .makeParseRequest(instructions: "sys", input: "x", schema: CaptureSchema.capture)
        #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "AIza-test")
        let config = body(request)["generationConfig"] as? [String: Any]
        #expect(config?["responseMimeType"] as? String == "application/json")
    }

    @Test func extractsTextFromEachProvider() throws {
        let claude: [String: Any] = ["stop_reason": "end_turn", "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": "{\"items\":[]}"]]]
        #expect(try CloudClient.extractText(from: claude, provider: .anthropic) == "{\"items\":[]}")

        let openAI: [String: Any] = ["status": "completed", "output": [["type": "reasoning"], ["type": "message", "content": [["type": "output_text", "text": "{}"]]]]]
        #expect(try CloudClient.extractText(from: openAI, provider: .openai) == "{}")

        let gemini: [String: Any] = ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": "{\"a\":"], ["text": "1}"]]]]]]
        #expect(try CloudClient.extractText(from: gemini, provider: .gemini) == "{\"a\":1}")
    }

    @Test func refusalsAndTruncationAreErrors() {
        #expect(throws: AIError.refused) {
            try CloudClient.extractText(from: ["stop_reason": "refusal", "content": []], provider: .anthropic)
        }
        #expect(throws: AIError.truncated) {
            try CloudClient.extractText(from: ["candidates": [["finishReason": "MAX_TOKENS"]]], provider: .gemini)
        }
        #expect(throws: AIError.refused) {
            try CloudClient.extractText(from: ["output": [["type": "message", "content": [["type": "refusal", "refusal": "no"]]]]], provider: .openai)
        }
    }

    @Test func decodingToleratesFencesMissingFieldsAndNumericAmounts() throws {
        let text = """
        ```json
        {"items":[{"type":"expense","title":"午餐","amount":35}],"followUpQuestion":""}
        ```
        """
        let capture = try CloudClient.decodeCapture(from: text)
        #expect(capture.items.first?.amount == "35")
        #expect(capture.items.first?.repeatFrequency == "none")
        #expect(capture.fillerPhrases.isEmpty)
    }
}

/// Agreeing to send text to one provider doesn't cover another, or a custom endpoint moved to a new host.
struct CloudConsentTests {
    @Test func consentIsPerProvider() {
        let defaults = UserDefaults.standard
        let keys = [AISettings.consentKey, AISettings.consentScopeKey, AISettings.providerKey, AISettings.customBaseURLKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }

        defaults.set(AIProvider.anthropic.rawValue, forKey: AISettings.providerKey)
        AISettings.hasCloudConsent = true
        #expect(AISettings.hasCloudConsent)

        defaults.set(AIProvider.gemini.rawValue, forKey: AISettings.providerKey)
        #expect(!AISettings.hasCloudConsent)
        defaults.set(AIProvider.anthropic.rawValue, forKey: AISettings.providerKey)
        #expect(AISettings.hasCloudConsent)

        defaults.set(AIProvider.custom.rawValue, forKey: AISettings.providerKey)
        defaults.set("https://api.deepseek.com/v1", forKey: AISettings.customBaseURLKey)
        AISettings.hasCloudConsent = true
        #expect(AISettings.hasCloudConsent)
        defaults.set("https://api.moonshot.cn/v1", forKey: AISettings.customBaseURLKey)
        #expect(!AISettings.hasCloudConsent)

        AISettings.hasCloudConsent = false
        #expect(!AISettings.hasCloudConsent)
        #expect(defaults.string(forKey: AISettings.consentScopeKey) == nil)
    }
}

struct CaptureDraftTests {
    private let container = AppSchema.makeContainer(inMemory: true)

    private func seeded() -> (ModelContext, [LedgerCategory], [Account]) {
        let context = container.mainContext
        SeedData.seedDefaultsIfNeeded(context)
        let categories = (try? context.fetch(FetchDescriptor<LedgerCategory>())) ?? []
        let accounts = (try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        return (context, categories, accounts)
    }

    /// The scenario from the design: lunch, a vague credit-card bill, a passport due "next March".
    private var capture: ParsedCapture {
        var lunch = ParsedItem()
        lunch.type = "expense"; lunch.title = "午餐"; lunch.amount = "35"; lunch.category = "餐饮"
        lunch.account = "电子钱包"; lunch.date = "2026-10-11"; lunch.time = "12:00"

        var card = ParsedItem()
        card.type = "bill"; card.title = "信用卡还款"; card.amount = "2000"; card.amountIsApproximate = true
        card.billKind = "creditCard"; card.date = "2026-10-15"; card.repeatFrequency = "monthly"; card.repeatMonthDay = 15
        card.reminderDaysBefore = [3, 0]; card.account = "储蓄卡"

        var passport = ParsedItem()
        passport.type = "expiry"; passport.title = "护照"; passport.expiryKind = "document"
        passport.date = "2027-03-01"; passport.dateIsApproximate = true

        return ParsedCapture(items: [lunch, card, passport],
                             fillerPhrases: ["嗯…那个", "啊对，"],
                             followUpQuestion: "信用卡这期具体多少？")
    }

    @Test func draftsMatchNamesAndFlagGuesses() {
        let (_, categories, accounts) = seeded()
        let drafts = capture.items.map { CaptureDraft(item: $0, categories: categories, accounts: accounts, baseCurrency: "CNY") }

        #expect(drafts[0].kind == .expense)
        #expect(drafts[0].category?.name == "餐饮")
        #expect(drafts[0].account?.name == "电子钱包")
        #expect(drafts[0].hasTime)
        #expect(drafts[0].problem == nil)

        #expect(drafts[1].uncertain.contains("amount"))
        #expect(drafts[1].recurrence?.monthDay == 15)
        #expect(drafts[1].toAccount?.kind == .creditCard)
        #expect(drafts[1].reminderRules.map(\.daysBefore) == [3, 0])

        #expect(drafts[2].uncertain.contains("date"))
        #expect(drafts[2].reminderRules.map(\.daysBefore) == [90, 30, 7])
    }

    @Test func savingCreatesTheRightRecords() throws {
        let (context, categories, accounts) = seeded()
        for item in capture.items {
            CaptureDraft(item: item, categories: categories, accounts: accounts, baseCurrency: "CNY").save(in: context, baseCurrency: "CNY")
        }
        let entries = try context.fetch(FetchDescriptor<LedgerEntry>())
        #expect(entries.count == 1)
        #expect(entries.first?.source == .ai)
        #expect(entries.first?.amount == 35)

        let bills = try context.fetch(FetchDescriptor<Bill>())
        #expect(bills.first?.isAmountEstimated == true)
        #expect(bills.first?.creditAccount?.kind == .creditCard)
        #expect(bills.first?.category == nil)

        let expiries = try context.fetch(FetchDescriptor<ExpiryItem>())
        #expect(expiries.first?.isDayUncertain == true)
    }

    @Test func mentioningAnExistingBillUpdatesItInsteadOfDuplicating() throws {
        let (context, categories, accounts) = seeded()
        let existing = Bill(name: "信用卡还款", kind: .creditCard, amount: 1500, nextDueDate: .now, recurrence: .monthly(day: 15))
        context.insert(existing)

        var item = ParsedItem()
        item.type = "bill"; item.title = "信用卡还款"; item.billKind = "creditCard"
        item.amount = "2180"; item.date = "2026-10-15"
        var draft = CaptureDraft(item: item, categories: categories, accounts: accounts, baseCurrency: "CNY")
        draft.linkExisting(bills: [existing], expiries: [])
        #expect(draft.existingBill === existing)

        draft.save(in: context, baseCurrency: "CNY")
        #expect(try context.fetchCount(FetchDescriptor<Bill>()) == 1)
        #expect(existing.amount == 2180)

        draft.updatesExisting = false
        draft.save(in: context, baseCurrency: "CNY")
        #expect(try context.fetchCount(FetchDescriptor<Bill>()) == 2)
    }

    /// What the model left without a category gets one from what it was for, or 其他, flagged.
    @Test func moneyAlwaysGetsACategory() {
        let (_, categories, accounts) = seeded()
        func draft(_ title: String, category: String = "", type: String = "expense", quote: String = "") -> CaptureDraft {
            var item = ParsedItem()
            item.type = type; item.title = title; item.amount = "100"; item.category = category; item.quote = quote
            return CaptureDraft(item: item, categories: categories, accounts: accounts, baseCurrency: "CNY")
        }
        // 「车」 in a misheard 「铺车暖气」 doesn't outweigh 暖气 and 瓷砖.
        #expect(draft("铺车暖气和购买瓷砖").category?.seedKey == "housing")
        #expect(!draft("铺车暖气和购买瓷砖").uncertain.contains("category"))
        #expect(draft("费用", quote: "装修师傅的工钱和买瓷砖").category?.seedKey == "housing")
        #expect(draft("手机费").category?.seedKey == "telecom")
        #expect(draft("洗车").category?.seedKey == "transport")
        #expect(draft("杂七杂八").category?.seedKey == "other-expense")
        #expect(draft("杂七杂八").uncertain.contains("category"))
        #expect(draft("报销", type: "income").category?.seedKey == "other-income")
        #expect(draft("年终奖", type: "income").category?.seedKey == "bonus")
        // A name the model made up still lands on the person's own category when it matches.
        #expect(draft("午饭", category: "吃饭").category?.seedKey == "food")
    }

    @Test func missingAmountBlocksSaving() {
        let (_, categories, accounts) = seeded()
        var item = ParsedItem()
        item.type = "expense"; item.title = "打车"
        let draft = CaptureDraft(item: item, categories: categories, accounts: accounts, baseCurrency: "CNY")
        #expect(draft.problem == "缺少金额")
    }

    @Test func fillersAreStruckThrough() {
        let text = CaptureDraft.highlighted("嗯…那个今天中午吃饭花了三十五", fillers: ["嗯…那个"])
        let struck = text.runs.filter { $0.strikethroughStyle != nil }.map { String(text[$0.range].characters) }
        #expect(struck == ["嗯…那个"])
    }

    @Test func unusableOnDeviceResultsAreRejected() {
        var item = ParsedItem()
        item.type = "expense"; item.title = "午餐"; item.amount = "三十五"
        #expect(!CaptureEngine.isUsable(ParsedCapture(items: [item])))
        item.amount = "35"
        #expect(CaptureEngine.isUsable(ParsedCapture(items: [item])))
        #expect(!CaptureEngine.isUsable(ParsedCapture()))
    }

    @Test func impossibleDatesDoNotParse() {
        #expect(DraftParsing.date("2026-02-30") == nil)
        #expect(DraftParsing.date("2026-10-15", time: "18:30") != nil)
    }
}
