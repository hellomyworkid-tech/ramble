import Foundation
import SwiftData
import Testing
@testable import Ramble

struct OutstandingCueTests {
    @Test(arguments: [
        ("张三还欠我两千块", OutstandingDirection.receivable, "张三"),
        ("借给小王五千", .receivable, "小王"),
        ("客户的尾款五万还没收到", .receivable, ""),
        ("帮李姐垫了三百块快递费", .receivable, "李姐"),
        ("老周还没还我那一千", .receivable, "老周"),
        ("客户还欠五万", .receivable, "客户"),
        ("还欠装修师傅三千工钱", .payable, "装修师傅"),
        ("我欠张三两千", .payable, "张三"),
        ("跟李四借了两千", .payable, "李四"),
        ("师傅的工钱还没付给师傅的", .payable, "师傅"),
        ("信用卡欠款两千", .payable, ""),
    ])
    func owedMoneyIsSpotted(_ text: String, _ direction: OutstandingDirection, _ who: String) {
        #expect(OutstandingCues.direction(in: text) == direction, "\(text)")
        if !who.isEmpty {
            #expect(OutstandingCues.counterparty(in: text, direction: direction) == who, "\(text)")
        }
    }

    @Test(arguments: ["中午吃饭花了三十五", "收回欠款五千", "话费欠费了充了一百", "买瓷砖花了三千二", "还了信用卡两千"])
    func moneyThatMovedIsLeftAlone(_ text: String) {
        #expect(OutstandingCues.direction(in: text) == nil, "\(text)")
    }
}

@MainActor
struct OutstandingTests {
    private let container = AppSchema.makeContainer(inMemory: true)

    private func seeded() -> (ModelContext, [LedgerCategory], [Account]) {
        let context = container.mainContext
        SeedData.seedDefaultsIfNeeded(context)
        let categories = (try? context.fetch(FetchDescriptor<LedgerCategory>())) ?? []
        let accounts = (try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        return (context, categories, accounts)
    }

    @Test func settlingRecordsIncomeAndDeletingItPutsItBack() throws {
        let (context, categories, accounts) = seeded()
        let loan = Outstanding(direction: .receivable, title: "借款", counterparty: "张三", amount: 2000)
        context.insert(loan)
        loan.category = categories.first { $0.seedKey == "other-income" }
        loan.account = accounts.first { $0.kind == .debitCard }

        let part = loan.settle(amount: 500, on: .now, account: nil, in: context)
        #expect(part.kind == .income && part.amount == 500 && part.source == .outstanding)
        #expect(part.note == "借款 · 张三" && part.category === loan.category && part.account === loan.account)
        #expect(loan.remaining == 1500 && !loan.isSettled)

        let rest = loan.settle(amount: loan.remaining, on: .now, account: accounts.first { $0.kind == .cash }, in: context)
        #expect(rest.account?.kind == .cash)
        #expect(loan.isSettled && loan.remaining == 0)

        context.delete(rest)
        try context.save()
        #expect(loan.remaining == 1500 && !loan.isSettled)
    }

    @Test func payablesRecordExpenseAndCanBeOverdue() {
        let (context, _, _) = seeded()
        let wages = Outstanding(direction: .payable, title: "工钱", counterparty: "装修师傅", amount: 3000,
                                dueDate: Calendar.current.date(byAdding: .day, value: -2, to: .now))
        context.insert(wages)
        #expect(wages.isOverdue())
        #expect(wages.settle(amount: 3000, on: .now, account: nil, in: context).kind == .expense)
        #expect(!wages.isOverdue())
        #expect(Outstanding(direction: .payable, title: "x", amount: 1).displayTitle == "x")
    }

    /// 「张三还欠我两千」 read as income by any model is saved as 应收, not counted as income.
    @Test func capturedDebtsBecomeOutstandingNotIncome() throws {
        let (context, categories, accounts) = seeded()
        var item = ParsedItem()
        item.type = "income"; item.title = "借款"; item.amount = "2000"; item.quote = "张三还欠我两千块"
        let draft = CaptureDraft(item: item, categories: categories, accounts: accounts, baseCurrency: "CNY")
        #expect(draft.kind == .receivable && draft.counterparty == "张三")
        #expect(draft.date == nil && draft.problem == nil)
        #expect(draft.category?.kind == .income)

        guard case .outstanding(let saved)? = draft.save(in: context, baseCurrency: "CNY") else {
            Issue.record("not saved as outstanding")
            return
        }
        #expect(saved.direction == .receivable && saved.amount == 2000 && saved.counterparty == "张三")
        #expect(try context.fetchCount(FetchDescriptor<LedgerEntry>()) == 0)

        var payable = ParsedItem()
        payable.type = "payable"; payable.title = "工钱"; payable.amount = "3000"; payable.counterparty = "装修师傅"
        payable.date = "2026-11-01"
        let owed = CaptureDraft(item: payable, categories: categories, accounts: accounts, baseCurrency: "CNY")
        #expect(owed.kind == .payable && owed.counterparty == "装修师傅" && owed.date != nil)
        #expect(owed.category?.kind == .expense)
    }

    @Test func theOnDeviceModelsDebtsAreConverted() {
        let now = DraftParsing.date("2026-10-14", time: "19:40")!
        let items = OpenCapture(items: [
            OpenCaptureItem(type: "income", title: "张三", amount: "2000", when: "", category: ""),
            OpenCaptureItem(type: "expense", title: "工钱", amount: "3000", when: "月底", category: ""),
            OpenCaptureItem(type: "expense", title: "午饭", amount: "35", when: "", category: "餐饮"),
        ]).parsed(input: "张三还欠我两千块，还欠装修师傅三千工钱月底给，然后中午吃饭花了三十五", now: now).items
        #expect(items[0].type == "receivable" && items[0].counterparty == "张三" && items[0].title == "欠款")
        // Owed money may be due ahead, unlike money already spent.
        #expect(items[1].type == "payable" && items[1].counterparty == "装修师傅" && items[1].date == "2026-10-31")
        #expect(items[2].type == "expense")
    }

    /// What Qwen3 4B on the phone made of it: a note named 其他 and a to-do.
    @Test func debtsTheModelFiledAsANoteAndAToDo() {
        let now = DraftParsing.date("2026-10-14", time: "19:40")!
        let items = OpenCapture(items: [
            OpenCaptureItem(type: "note", title: "其他", amount: "2000", when: "", category: ""),
            OpenCaptureItem(type: "task", title: "欠装修师傅3千工钱给", amount: "", when: "月底", category: ""),
        ]).parsed(input: "张三还欠我两千块，还欠装修师傅三千工钱月底给", now: now).items
        #expect(items.map(\.type) == ["receivable", "payable"])
        #expect(items[0].counterparty == "张三" && items[0].amount == "2000" && items[0].date.isEmpty)
        #expect(items[1].counterparty == "装修师傅" && items[1].amount == "3000" && items[1].date == "2026-10-31")
    }

    /// Also from the phone: 「一共花了82,000」 put on both things paid for.
    @Test func aTotalSaidOnceIsRecordedOnce() {
        let now = DraftParsing.date("2026-10-14", time: "19:40")!
        let items = OpenCapture(items: [
            OpenCaptureItem(type: "expense", title: "铺车暖气", amount: "82000", when: "", category: "装修"),
            OpenCaptureItem(type: "expense", title: "购买瓷砖", amount: "82000", when: "", category: "装修"),
        ]).parsed(input: "呃，今天那个。铺车暖气的费用和购买瓷砖的费用一共花了82,000块钱。", now: now).items
        #expect(items.count == 1)
        #expect(items.first?.title == "铺车暖气和购买瓷砖" && items.first?.amount == "82000")

        // Two things that really cost the same stay two.
        let two = OpenCapture(items: [
            OpenCaptureItem(type: "expense", title: "午饭", amount: "35", when: "", category: "餐饮"),
            OpenCaptureItem(type: "expense", title: "晚饭", amount: "35", when: "", category: "餐饮"),
        ]).parsed(input: "午饭三十五晚饭也是三十五", now: now).items
        #expect(two.count == 2)
    }

    @Test func aCatchAllCategoryGivesWayToWhatWasSaid() {
        let (_, categories, accounts) = seeded()
        var item = ParsedItem()
        item.type = "expense"; item.title = "买瓷砖"; item.amount = "3200"; item.category = "购物"
        #expect(CaptureDraft(item: item, categories: categories, accounts: accounts, baseCurrency: "CNY").category?.seedKey == "housing")
        item.title = "买衣服"
        #expect(CaptureDraft(item: item, categories: categories, accounts: accounts, baseCurrency: "CNY").category?.seedKey == "shopping")
    }

    @Test func outstandingSurvivesABackupAndOldBackupsStillRestore() throws {
        let (context, categories, _) = seeded()
        let loan = Outstanding(direction: .receivable, title: "借款", counterparty: "张三", amount: 2000, dueDate: .now)
        context.insert(loan)
        loan.category = categories.first { $0.seedKey == "other-income" }
        loan.settle(amount: 500, on: .now, account: nil, in: context)
        try context.save()

        let data = try Backup.encoder().encode(try Backup.make(from: context))
        let target = AppSchema.makeContainer(inMemory: true)
        try Backup.restore(try Backup.read(data), into: target.mainContext)
        let restored = try #require(try target.mainContext.fetch(FetchDescriptor<Outstanding>()).first)
        #expect(restored.counterparty == "张三" && restored.dueDate != nil && restored.category?.seedKey == "other-income")
        #expect(restored.remaining == 1500)

        // A backup made before 应收应付 existed has no such list.
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["outstandings"] = nil
        let old = try JSONSerialization.data(withJSONObject: json)
        #expect(try Backup.read(old).outstandings == nil)
        try Backup.restore(try Backup.read(old), into: target.mainContext)
        #expect(try target.mainContext.fetchCount(FetchDescriptor<Outstanding>()) == 0)
    }
}

/// Answers each request from a table, so the client can be tested without a network.
nonisolated final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: Any]))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = request
        // URLSession moves the body into a stream; read it back for the assertions.
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            request.httpBody = data
        }
        Self.requests.append(request)
        let (status, json) = Self.handler?(request) ?? (500, [:])
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

@Suite(.serialized)
struct CustomEndpointTests {
    private func body(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    @Test func addressesAreTidiedAndPlainHTTPOnlyOnTheLocalNetwork() {
        #expect(AISettings.normalizedBaseURL("api.deepseek.com/v1/")?.absoluteString == "https://api.deepseek.com/v1")
        #expect(AISettings.normalizedBaseURL(" https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions ")?.absoluteString
            == "https://dashscope.aliyuncs.com/compatible-mode/v1")
        #expect(AISettings.normalizedBaseURL("http://192.168.1.20:11434/v1")?.absoluteString == "http://192.168.1.20:11434/v1")
        #expect(AISettings.normalizedBaseURL("http://my-mac.local:11434/v1") != nil)
        #expect(AISettings.normalizedBaseURL("http://api.example.com/v1") == nil)
        #expect(AISettings.normalizedBaseURL("ftp://x.com") == nil)
        #expect(AISettings.normalizedBaseURL("") == nil)
        #expect(CustomEndpointPreset.matching(URL(string: "https://api.deepseek.com/v1"))?.name == "DeepSeek")
    }

    @Test func requestsSpeakChatCompletionsWithJSONMode() throws {
        let client = CloudClient(provider: .custom, apiKey: "sk-test", model: "deepseek-chat",
                                 baseURL: URL(string: "https://api.deepseek.com/v1"))
        let request = try client.makeParseRequest(instructions: "sys", input: "午饭35", schema: CaptureSchema.capture)
        #expect(request.url?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let json = body(request)
        #expect(json["model"] as? String == "deepseek-chat")
        #expect((json["response_format"] as? [String: Any])?["type"] as? String == "json_object")
        let messages = json["messages"] as? [[String: Any]] ?? []
        #expect(messages.first?["role"] as? String == "system")
        #expect((messages.first?["content"] as? String)?.contains("\"counterparty\"") == true)
        #expect(messages.last?["content"] as? String == "午饭35")

        let withoutAddress = CloudClient(provider: .custom, apiKey: "k", model: "m")
        #expect(throws: AIError.badEndpoint) {
            try withoutAddress.makeParseRequest(instructions: "", input: "", schema: CaptureSchema.capture)
        }
    }

    @Test func repliesAreReadAndCutOffRepliesAreErrors() throws {
        let reply: [String: Any] = ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": "```json\n{\"items\":[]}\n```"]]]]
        #expect(try CloudClient.extractText(from: reply, provider: .custom).contains("{\"items\":[]}"))
        #expect(throws: AIError.truncated) {
            try CloudClient.extractText(from: ["choices": [["finish_reason": "length", "message": ["content": "{"]]]], provider: .custom)
        }
        #expect(throws: AIError.refused) {
            try CloudClient.extractText(from: ["choices": [["finish_reason": "content_filter", "message": [:]]]], provider: .custom)
        }
    }

    /// A service without JSON mode answers 400; the request is sent again without it.
    @Test func servicesWithoutJSONModeStillWork() async throws {
        StubProtocol.requests = []
        StubProtocol.handler = { request in
            let json = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            if json["response_format"] != nil {
                return (400, ["error": ["message": "response_format is not supported by this model"]])
            }
            return (200, ["choices": [["finish_reason": "stop", "message": ["content": #"{"items":[{"type":"expense","title":"午饭","amount":"35"}]}"#]]]])
        }
        var client = CloudClient(provider: .custom, apiKey: "k", model: "m", baseURL: URL(string: "https://api.example.com/v1"))
        client.session = StubProtocol.session()
        let capture = try await client.parse(instructions: "sys", input: "午饭35")
        #expect(capture.items.first?.title == "午饭")
        #expect(StubProtocol.requests.count == 2)
    }

    @Test func modelsAreListedFromTheEndpoint() async throws {
        StubProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://api.example.com/v1/models")
            return (200, ["object": "list", "data": [["id": "qwen-plus"], ["id": "qwen-max"]]])
        }
        var client = CloudClient(provider: .custom, apiKey: "k", model: "", baseURL: URL(string: "https://api.example.com/v1"))
        client.session = StubProtocol.session()
        #expect(try await client.listModels().map(\.id) == ["qwen-max", "qwen-plus"])
    }
}
