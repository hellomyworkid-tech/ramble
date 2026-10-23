import Foundation

nonisolated enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case anthropic, openai, gemini
    /// Any service that speaks OpenAI's Chat Completions: DeepSeek, 通义千问, Kimi, 智谱, a local Ollama…
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: "Claude"
        case .openai: "ChatGPT"
        case .gemini: "Gemini"
        case .custom: AISettings.customName
        }
    }

    /// Who receives the text, for the consent prompts: the custom endpoint's host.
    var vendor: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .gemini: "Google"
        case .custom: AISettings.customBaseURL?.host() ?? String(localized: "自定义接口")
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: "claude-opus-5-5"
        case .openai: "gpt-6-astra"
        case .gemini: "gemini-3.8-flash"
        case .custom: CustomEndpointPreset.matching(AISettings.customBaseURL)?.suggestedModels.first ?? ""
        }
    }

    /// Shown before the person fetches the live list from their account.
    var suggestedModels: [String] {
        switch self {
        case .anthropic: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
        case .openai: ["gpt-6-astra"]
        case .gemini: ["gemini-3.8-flash", "gemini-3.5-flash-lite"]
        case .custom: CustomEndpointPreset.matching(AISettings.customBaseURL)?.suggestedModels ?? []
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: "sk-ant-…"
        case .openai, .custom: "sk-…"
        case .gemini: "AIza…"
        }
    }

    var keyPageURL: URL? {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")
        case .openai: URL(string: "https://platform.openai.com/api-keys")
        case .gemini: URL(string: "https://aistudio.google.com/apikey")
        case .custom: CustomEndpointPreset.matching(AISettings.customBaseURL)?.keyPage
        }
    }
}

/// Services known to accept OpenAI-style requests, to fill in the custom endpoint.
nonisolated struct CustomEndpointPreset: Identifiable {
    let name: String
    let baseURL: String
    let keyPage: URL?
    let suggestedModels: [String]

    var id: String { baseURL }

    static let all: [CustomEndpointPreset] = [
        .init(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1",
              keyPage: URL(string: "https://platform.deepseek.com/api_keys"), suggestedModels: ["deepseek-chat", "deepseek-reasoner"]),
        .init(name: "通义千问", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
              keyPage: URL(string: "https://bailian.console.aliyun.com/"), suggestedModels: ["qwen-plus", "qwen-max", "qwen-flash"]),
        .init(name: "Kimi", baseURL: "https://api.moonshot.cn/v1",
              keyPage: URL(string: "https://platform.moonshot.cn/console/api-keys"), suggestedModels: []),
        .init(name: "智谱 GLM", baseURL: "https://open.bigmodel.cn/api/paas/v4",
              keyPage: URL(string: "https://open.bigmodel.cn/usercenter/apikeys"), suggestedModels: []),
        .init(name: "豆包", baseURL: "https://ark.cn-beijing.volces.com/api/v3",
              keyPage: URL(string: "https://console.volcengine.com/ark"), suggestedModels: []),
        .init(name: "硅基流动", baseURL: "https://api.siliconflow.cn/v1",
              keyPage: URL(string: "https://cloud.siliconflow.cn/account/ak"), suggestedModels: []),
        .init(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",
              keyPage: URL(string: "https://openrouter.ai/keys"), suggestedModels: []),
    ]

    static func matching(_ url: URL?) -> CustomEndpointPreset? {
        guard let url else { return nil }
        return all.first { URL(string: $0.baseURL)?.host() == url.host() }
    }
}

nonisolated enum AIError: LocalizedError, Equatable {
    case missingKey(AIProvider)
    case invalidKey(AIProvider)
    case rateLimited(AIProvider)
    case server(AIProvider, String)
    case refused
    case truncated
    case badResponse(String)
    case network(String)
    case onDeviceUnavailable(String)
    case cloudNotConfigured
    case needsConsent(AIProvider)
    case nothingFound
    case originalsNeedCloud
    case originalsTooLarge
    case badEndpoint

    var errorDescription: String? {
        switch self {
        case .missingKey(let provider):
            String(localized: "还没有填 \(provider.displayName) 的 API Key。")
        case .invalidKey(let provider):
            String(localized: "\(provider.displayName) 的 API Key 无效或没有权限。")
        case .rateLimited(let provider):
            String(localized: "\(provider.displayName) 请求太频繁或额度用完了，稍后再试。")
        case .server(let provider, let message):
            String(localized: "\(provider.displayName) 返回错误：\(message)")
        case .refused:
            String(localized: "模型拒绝处理这段内容。")
        case .truncated:
            String(localized: "模型的回复被截断了，请把内容分成几次说。")
        case .badResponse(let detail):
            String(localized: "没能读懂模型的回复（\(detail)）。")
        case .network(let message):
            String(localized: "网络错误：\(message)")
        case .onDeviceUnavailable(let reason):
            reason
        case .cloudNotConfigured:
            String(localized: "本机模型不可用，也还没有设置云端 AI。")
        case .needsConsent(let provider):
            String(localized: "需要你同意把这段文字发送给 \(provider.displayName)。")
        case .nothingFound:
            String(localized: "没有从这段话里整理出可以记录的内容。")
        case .originalsNeedCloud:
            String(localized: "要让 AI 直接看原件，需要先在「AI 设置」里填一个云端 AI 的 Key。")
        case .originalsTooLarge:
            String(localized: "原件太大（合计超过 15MB），没法整个发送。可以只选其中几页的照片再试。")
        case .badEndpoint:
            String(localized: "自定义接口的地址不对：需要 https:// 开头（局域网里的服务可以用 http://），例如 https://api.deepseek.com/v1。")
        }
    }
}

/// A photo or PDF shown to the model as is, when on-device text recognition wasn't enough.
nonisolated struct CloudAttachment: Equatable {
    let data: Data
    let mimeType: String
    let fileName: String

    var isPDF: Bool { mimeType == "application/pdf" }
    var base64: String { data.base64EncodedString() }
}

nonisolated struct AIModelInfo: Identifiable, Hashable {
    let id: String
    let displayName: String
}

/// Calls a provider directly with the person's own API key.
nonisolated struct CloudClient {
    let provider: AIProvider
    let apiKey: String
    let model: String
    var thinking: AIThinking = .fast
    /// The custom provider's endpoint, up to and including the version (…/v1).
    var baseURL: URL?
    var session: URLSession = .shared

    // MARK: Parse

    func parse(instructions: String, input: String, schema: SchemaNode = CaptureSchema.capture,
               attachments: [CloudAttachment] = []) async throws -> ParsedCapture {
        try await generate(ParsedCapture.self, instructions: instructions, input: input, schema: schema, attachments: attachments)
    }

    /// One structured request: the reply is decoded as `T`, which must match `schema`.
    func generate<T: Decodable>(_ type: T.Type, instructions: String, input: String, schema: SchemaNode,
                                attachments: [CloudAttachment] = []) async throws -> T {
        let request = try makeParseRequest(instructions: instructions, input: input, schema: schema, attachments: attachments)
        let json: [String: Any]
        do {
            json = try await send(request)
        } catch AIError.server(.custom, let message) where message.localizedCaseInsensitiveContains("response_format")
                    || message.localizedCaseInsensitiveContains("json") {
            // Some services don't take JSON mode; the instructions already ask for JSON.
            json = try await send(makeParseRequest(instructions: instructions, input: input, schema: schema,
                                                   attachments: attachments, jsonMode: false))
        }
        let text = try Self.extractText(from: json, provider: provider)
        return try Self.decode(type, from: text)
    }

    func makeParseRequest(instructions: String, input: String, schema: SchemaNode,
                          attachments: [CloudAttachment] = [], jsonMode: Bool = true) throws -> URLRequest {
        var request: URLRequest
        var body: [String: Any]
        switch provider {
        case .custom:
            guard let baseURL else { throw AIError.badEndpoint }
            request = URLRequest(url: baseURL.appending(path: "chat/completions"))
            if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            // JSON mode is the one structured-output switch these services share; the schema goes in the instructions.
            let system = instructions + "\n\nReply with only a JSON object matching this JSON schema:\n" + Self.jsonString(schema.jsonSchema)
            body = [
                "model": model,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": Self.chatContent(input, attachments: attachments)],
                ],
                "stream": false,
            ]
            if jsonMode { body["response_format"] = ["type": "json_object"] }

        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            var system = instructions
            var outputConfig: [String: Any] = [:]
            if Self.anthropicSupportsStructuredOutput(model) {
                outputConfig["format"] = ["type": "json_schema", "schema": schema.jsonSchema]
            } else {
                system += "\n\nReply with only a JSON object matching this schema:\n" + Self.jsonString(schema.jsonSchema)
            }
            // Extraction is a simple task: low effort keeps it fast without losing quality.
            if Self.anthropicSupportsEffort(model) {
                outputConfig["effort"] = Self.anthropicEffort(thinking)
            }
            body = [
                "model": model,
                "max_tokens": 16000,
                "system": system,
                "messages": [["role": "user", "content": Self.anthropicContent(input, attachments: attachments)]],
            ]
            if !outputConfig.isEmpty { body["output_config"] = outputConfig }
            // If a safety classifier declines, let the API retry on a suitable model.
            if Self.anthropicSupportsDefaultFallback(model) {
                request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
            }

        case .openai:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body = [
                "model": model,
                "input": [
                    ["role": "system", "content": instructions],
                    ["role": "user", "content": Self.openAIContent(input, attachments: attachments)],
                ],
                "text": [
                    "format": [
                        "type": "json_schema",
                        "name": "capture",
                        "schema": schema.jsonSchema,
                        "strict": true,
                    ],
                ],
            ]
            // Reasoning models think before answering by default; extraction doesn't need it.
            if let effort = Self.openAIReasoningEffort(model, thinking: thinking) { body["reasoning"] = ["effort": effort] }

        case .gemini:
            let path = model.hasPrefix("models/") ? model : "models/\(model)"
            request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/\(path):generateContent")!)
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            var generationConfig: [String: Any] = [
                "responseMimeType": "application/json",
                "responseSchema": schema.geminiSchema,
            ]
            // Gemini 3.8 Flash thinks at "medium" unless told otherwise, which was most of the wait.
            if let config = Self.geminiThinkingConfig(model, thinking: thinking) { generationConfig["thinkingConfig"] = config }
            body = [
                "systemInstruction": ["parts": [["text": instructions]]],
                "contents": [["role": "user", "parts": Self.geminiParts(input, attachments: attachments)]],
                "generationConfig": generationConfig,
            ]
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Reading a whole scanned report takes the model a while.
        request.timeoutInterval = attachments.isEmpty ? thinking.timeout : max(180, thinking.timeout)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: Files in the request

    /// Plain text stays a string; with files, the files come first and the text last.
    static func anthropicContent(_ input: String, attachments: [CloudAttachment]) -> Any {
        guard !attachments.isEmpty else { return input }
        var blocks: [[String: Any]] = attachments.map { file in
            [
                "type": file.isPDF ? "document" : "image",
                "source": ["type": "base64", "media_type": file.mimeType, "data": file.base64],
            ]
        }
        blocks.append(["type": "text", "text": input])
        return blocks
    }

    static func openAIContent(_ input: String, attachments: [CloudAttachment]) -> Any {
        guard !attachments.isEmpty else { return input }
        var parts: [[String: Any]] = attachments.map { file in
            let url = "data:\(file.mimeType);base64,\(file.base64)"
            return file.isPDF
                ? ["type": "input_file", "filename": file.fileName, "file_data": url]
                : ["type": "input_image", "image_url": url]
        }
        parts.append(["type": "input_text", "text": input])
        return parts
    }

    /// Chat Completions: images as data URLs, PDFs as files (for services that read them).
    static func chatContent(_ input: String, attachments: [CloudAttachment]) -> Any {
        guard !attachments.isEmpty else { return input }
        var parts: [[String: Any]] = attachments.map { file in
            let url = "data:\(file.mimeType);base64,\(file.base64)"
            return file.isPDF
                ? ["type": "file", "file": ["filename": file.fileName, "file_data": url]]
                : ["type": "image_url", "image_url": ["url": url]]
        }
        parts.append(["type": "text", "text": input])
        return parts
    }

    static func geminiParts(_ input: String, attachments: [CloudAttachment]) -> [[String: Any]] {
        var parts: [[String: Any]] = attachments.map { file in
            ["inlineData": ["mimeType": file.mimeType, "data": file.base64]]
        }
        parts.append(["text": input])
        return parts
    }

    /// Pulls the model's text out of each provider's response envelope.
    static func extractText(from json: [String: Any], provider: AIProvider) throws -> String {
        switch provider {
        case .anthropic:
            let stopReason = json["stop_reason"] as? String
            if stopReason == "refusal" { throw AIError.refused }
            if stopReason == "max_tokens" { throw AIError.truncated }
            let blocks = json["content"] as? [[String: Any]] ?? []
            let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw AIError.badResponse("no text") }
            return text

        case .openai:
            if json["status"] as? String == "incomplete" { throw AIError.truncated }
            let output = json["output"] as? [[String: Any]] ?? []
            var text = ""
            for item in output where item["type"] as? String == "message" {
                for part in item["content"] as? [[String: Any]] ?? [] {
                    switch part["type"] as? String {
                    case "output_text": text += part["text"] as? String ?? ""
                    case "refusal": throw AIError.refused
                    default: break
                    }
                }
            }
            guard !text.isEmpty else { throw AIError.badResponse("no output_text") }
            return text

        case .custom:
            let choice = (json["choices"] as? [[String: Any]])?.first ?? [:]
            switch choice["finish_reason"] as? String {
            case "length": throw AIError.truncated
            case "content_filter": throw AIError.refused
            default: break
            }
            let message = choice["message"] as? [String: Any] ?? [:]
            if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw AIError.refused }
            var text = message["content"] as? String ?? ""
            if text.isEmpty, let parts = message["content"] as? [[String: Any]] {
                text = parts.compactMap { $0["text"] as? String }.joined()
            }
            guard !text.isEmpty else { throw AIError.badResponse("no content") }
            return text

        case .gemini:
            if let feedback = json["promptFeedback"] as? [String: Any], feedback["blockReason"] != nil {
                throw AIError.refused
            }
            let candidate = (json["candidates"] as? [[String: Any]])?.first ?? [:]
            switch candidate["finishReason"] as? String {
            case "SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII": throw AIError.refused
            case "MAX_TOKENS": throw AIError.truncated
            default: break
            }
            let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            let text = parts.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw AIError.badResponse("no candidates") }
            return text
        }
    }

    static func decodeCapture(from text: String) throws -> ParsedCapture {
        try decode(ParsedCapture.self, from: text)
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        // Tolerate a model that wraps the JSON in prose or a code fence.
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            throw AIError.badResponse("no JSON")
        }
        let data = Data(text[start...end].utf8)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AIError.badResponse("JSON")
        }
    }

    // MARK: Models

    func listModels() async throws -> [AIModelInfo] {
        let json = try await send(try makeModelsRequest())
        switch provider {
        case .custom:
            let data = json["data"] as? [[String: Any]] ?? []
            return data.compactMap { $0["id"] as? String }.sorted().map { AIModelInfo(id: $0, displayName: $0) }
        case .anthropic:
            let data = json["data"] as? [[String: Any]] ?? []
            return data.compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                return AIModelInfo(id: id, displayName: item["display_name"] as? String ?? id)
            }
        case .openai:
            let excluded = ["audio", "realtime", "tts", "transcribe", "image", "embedding", "moderation", "search", "whisper", "dall-e", "davinci", "babbage"]
            let data = json["data"] as? [[String: Any]] ?? []
            return data.compactMap { $0["id"] as? String }
                .filter { id in id.hasPrefix("gpt") || id.hasPrefix("o") }
                .filter { id in !excluded.contains { id.contains($0) } }
                .sorted(by: >)
                .map { AIModelInfo(id: $0, displayName: $0) }
        case .gemini:
            let models = json["models"] as? [[String: Any]] ?? []
            return models.compactMap { item in
                guard let name = item["name"] as? String,
                      (item["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent")
                else { return nil }
                let id = name.replacingOccurrences(of: "models/", with: "")
                guard id.hasPrefix("gemini") else { return nil }
                return AIModelInfo(id: id, displayName: item["displayName"] as? String ?? id)
            }
        }
    }

    func makeModelsRequest() throws -> URLRequest {
        var request: URLRequest
        switch provider {
        case .custom:
            guard let baseURL else { throw AIError.badEndpoint }
            request = URLRequest(url: baseURL.appending(path: "models"))
            if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openai:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .gemini:
            request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200")!)
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        request.timeoutInterval = 30
        return request
    }

    // MARK: Transport

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AIError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch status {
        case 200..<300:
            return json
        case 401, 403:
            throw AIError.invalidKey(provider)
        case 429:
            throw AIError.rateLimited(provider)
        default:
            throw AIError.server(provider, Self.errorMessage(in: json) ?? "HTTP \(status)")
        }
    }

    private static func errorMessage(in json: [String: Any]) -> String? {
        // All three providers nest the message under "error".
        if let error = json["error"] as? [String: Any] {
            return error["message"] as? String
        }
        return json["error"] as? String
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Claude capabilities

    static func anthropicSupportsStructuredOutput(_ model: String) -> Bool {
        ["claude-fable", "claude-mythos", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-5", "claude-opus-4-1",
         "claude-sonnet-5", "claude-haiku-5", "claude-haiku-4-5"].contains { model.hasPrefix($0) }
    }

    static func anthropicSupportsEffort(_ model: String) -> Bool {
        ["claude-fable", "claude-mythos", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6",
         "claude-sonnet-5", "claude-sonnet-4-6", "claude-haiku-5"].contains { model.hasPrefix($0) }
    }

    /// Claude's effort levels map one to one.
    static func anthropicEffort(_ thinking: AIThinking) -> String {
        switch thinking {
        case .fast: "low"
        case .balanced: "medium"
        case .thorough: "high"
        }
    }

    /// Each OpenAI family's three lowest levels: GPT-5 starts at "minimal", 5.1 and later at
    /// "none", GPT-6 and the o-series at "low". Non-reasoning models (GPT-4.x) get nothing.
    static func openAIReasoningEffort(_ model: String, thinking: AIThinking = .fast) -> String? {
        let name = model.lowercased()
        let levels: [String]
        if name.hasPrefix("o1") || name.hasPrefix("o3") || name.hasPrefix("o4") {
            levels = ["low", "medium", "high"]
        } else {
            guard name.hasPrefix("gpt-"), let version = Double(name.dropFirst(4).prefix { $0.isNumber || $0 == "." }) else { return nil }
            switch version {
            case ..<5: return nil
            case 5 where !name.hasPrefix("gpt-5."): levels = ["minimal", "low", "medium"]
            case ..<6: levels = ["none", "low", "medium"]
            default: levels = ["low", "medium", "high"]
            }
        }
        return levels[thinking.index]
    }

    /// Gemini 3 and later take a thinking level (Flash-Lite goes down to "minimal", 3.8 Flash
    /// and Pro only to "low"); 2.5 takes a token budget, where 0 turns Flash's thinking off.
    static func geminiThinkingConfig(_ model: String, thinking: AIThinking = .fast) -> [String: Any]? {
        let name = model.lowercased().replacingOccurrences(of: "models/", with: "")
        guard name.hasPrefix("gemini-"),
              let version = Double(name.dropFirst(7).prefix { $0.isNumber || $0 == "." }) else { return nil }
        if version >= 3 {
            let levels = name.contains("flash-lite") ? ["minimal", "low", "high"] : ["low", "medium", "high"]
            return ["thinkingLevel": levels[thinking.index]]
        }
        if version >= 2.5 {
            // Pro can't switch thinking off; its smallest budget is 128.
            let budgets = name.contains("pro") ? [128, 2_048, 8_192] : [0, 2_048, 8_192]
            return ["thinkingBudget": budgets[thinking.index]]
        }
        return nil
    }

    static func anthropicSupportsDefaultFallback(_ model: String) -> Bool {
        ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"].contains(model)
    }
}
