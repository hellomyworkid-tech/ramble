import Foundation
import Security

nonisolated enum AIMode: String, CaseIterable, Identifiable {
    /// On-device first; cloud when the device can't, or the result looks wrong.
    case auto
    case onDevice
    case cloud

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .auto: "自动"
        case .onDevice: "仅本机"
        case .cloud: "仅云端"
        }
    }
}

/// How much a cloud model may think before answering. More thinking reads long, messy passages
/// and documents better but takes longer and costs more; recording an expense doesn't need it.
nonisolated enum AIThinking: String, CaseIterable, Identifiable {
    case fast, balanced, thorough

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .fast: "快速"
        case .balanced: "均衡"
        case .thorough: "深入"
        }
    }

    /// Position from lowest to highest, for picking from a provider's own list of levels.
    var index: Int {
        switch self {
        case .fast: 0
        case .balanced: 1
        case .thorough: 2
        }
    }

    /// Thinking takes time; give the request room for it.
    var timeout: TimeInterval {
        switch self {
        case .fast: 90
        case .balanced: 120
        case .thorough: 180
        }
    }
}

/// AI preferences. Plain settings live in UserDefaults; API keys only in the Keychain.
nonisolated enum AISettings {
    static let modeKey = "ai.mode"
    static let providerKey = "ai.provider"
    static let consentKey = "ai.cloudConsent"
    /// Which provider the consent was given for.
    static let consentScopeKey = "ai.cloudConsentScope"
    static let thinkingKey = "ai.thinking"
    static let customBaseURLKey = "ai.custom.baseURL"
    static let customNameKey = "ai.custom.name"

    /// The custom endpoint as typed, or nil when it isn't a usable address.
    static var customBaseURL: URL? {
        normalizedBaseURL(UserDefaults.standard.string(forKey: customBaseURLKey) ?? "")
    }

    /// What the custom endpoint is called in the app: the person's name for it, a known
    /// service's name, or 「自定义接口」.
    static var customName: String {
        let typed = (UserDefaults.standard.string(forKey: customNameKey) ?? "").trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { return typed }
        return CustomEndpointPreset.matching(customBaseURL)?.name ?? String(localized: "自定义接口")
    }

    /// 「api.deepseek.com」 → https://api.deepseek.com; a pasted …/chat/completions is trimmed back.
    /// Plain http only for the local network (a Mac or NAS running Ollama).
    static func normalizedBaseURL(_ text: String) -> URL? {
        var address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while address.hasSuffix("/") { address.removeLast() }
        for suffix in ["/chat/completions", "/completions", "/models"] where address.hasSuffix(suffix) {
            address.removeLast(suffix.count)
        }
        guard !address.isEmpty else { return nil }
        if !address.contains("://") { address = "https://" + address }
        guard let url = URL(string: address), let host = url.host(), !host.isEmpty,
              let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "https": return url
        case "http": return isLocal(host) ? url : nil
        default: return nil
        }
    }

    static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") || !host.contains(".") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))
    }

    /// Defaults to automatic: a sentence or two stays fast, long passages and documents get more.
    static var thinkingSetting: ThinkingSetting {
        ThinkingSetting(rawValue: UserDefaults.standard.string(forKey: thinkingKey) ?? "") ?? .auto
    }

    static func modelKey(_ provider: AIProvider) -> String { "ai.model.\(provider.rawValue)" }

    static var mode: AIMode {
        AIMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .auto
    }

    static var provider: AIProvider {
        AIProvider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .anthropic
    }

    static func model(for provider: AIProvider) -> String {
        let stored = UserDefaults.standard.string(forKey: modelKey(provider)) ?? ""
        return stored.isEmpty ? provider.defaultModel : stored
    }

    /// What consent covers: the provider, and for the custom endpoint the host it points at.
    static var consentScope: String {
        let provider = provider
        return provider == .custom ? "custom|\(customBaseURL?.host() ?? "")" : provider.rawValue
    }

    /// Agreed to send text to the current provider. Switching to another one, or pointing the
    /// custom endpoint at another host, asks again: the person agreed to one recipient, not any.
    static var hasCloudConsent: Bool {
        get {
            UserDefaults.standard.bool(forKey: consentKey)
                && UserDefaults.standard.string(forKey: consentScopeKey) == consentScope
        }
        set {
            UserDefaults.standard.set(newValue, forKey: consentKey)
            UserDefaults.standard.set(newValue ? consentScope : nil, forKey: consentScopeKey)
        }
    }

    /// The configured cloud client, or nil when the chosen provider has no key.
    static func cloudClient() -> CloudClient? {
        let provider = provider
        guard let key = AIKeychain.key(for: provider), !key.isEmpty else { return nil }
        let model = model(for: provider)
        if provider == .custom, customBaseURL == nil || model.isEmpty { return nil }
        // Callers set the level per request through ThinkingPlanner.
        return CloudClient(provider: provider, apiKey: key, model: model, thinking: thinkingSetting.fixed ?? .fast,
                           baseURL: provider == .custom ? customBaseURL : nil)
    }
}

/// API keys in the Keychain, this device only (never synced, never in backups).
nonisolated enum AIKeychain {
    private static let service = "com.zengji.suikouji.ai-keys"

    static func key(for provider: AIProvider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func setKey(_ key: String?, for provider: AIProvider) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        guard let key, !key.isEmpty else { return true }
        var item = base
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func hasKey(for provider: AIProvider) -> Bool {
        !(key(for: provider) ?? "").isEmpty
    }
}
