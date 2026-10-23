import Foundation

/// The language the person speaks in. Both engines follow it.
nonisolated enum SpeechLanguage: String, CaseIterable, Identifiable {
    case system, chinese, english

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .system: "跟随系统"
        case .chinese: "中文（普通话）"
        case .english: "English"
        }
    }

    /// Chinese or English: the system language decides when set to follow it.
    func resolved(systemLanguage: Locale.LanguageCode? = Locale.current.language.languageCode) -> SpeechLanguage {
        guard self == .system else { return self }
        return systemLanguage == .english ? .english : .chinese
    }

    var locale: Locale {
        resolved() == .english ? Locale(identifier: "en-US") : Locale(identifier: "zh-CN")
    }

    /// The language name Qwen3-ASR is told to expect.
    var modelLanguage: String {
        resolved() == .english ? "English" : "Chinese"
    }
}

/// Who turns speech into text.
nonisolated enum SpeechEngineKind: String, CaseIterable, Identifiable {
    /// Apple's on-device recognizer: nothing to download, text appears as you speak.
    case apple
    /// Alibaba's open Qwen3-ASR model, downloaded once and run on the phone through MLX.
    case qwen

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .apple: "iPhone 自带"
        case .qwen: "通义千问 Qwen3-ASR"
        }
    }
}

/// A speech model the person can download: mlx-community builds of Qwen3-ASR (Apache 2.0).
nonisolated struct SpeechModel: Identifiable, Equatable, Sendable {
    /// Hugging Face repository.
    let id: String
    let title: String
    let megabytes: Int
    /// Phones with less memory can't hold it next to the app and an AI model (iOS reports a little under the label).
    let minimumMemoryGB: Double
    let note: LocalizedStringResource

    static let qwen3_0_6b = SpeechModel(
        id: "mlx-community/Qwen3-ASR-0.6B-8bit", title: "Qwen3-ASR 0.6B", megabytes: 1_011, minimumMemoryGB: 3.5,
        note: "推荐。中文、口音和中英混说都比 Whisper 准得多，自动加标点，嘈杂环境也稳。")
    static let qwen3_1_7b = SpeechModel(
        id: "mlx-community/Qwen3-ASR-1.7B-4bit", title: "Qwen3-ASR 1.7B", megabytes: 1_608, minimumMemoryGB: 7.2,
        note: "更大，方言和口音重时更准一些。需要 8GB 内存的机型：iPhone 15 Pro、iPhone 16 全系及以后。")

    static let all = [qwen3_0_6b, qwen3_1_7b]

    static func find(_ id: String) -> SpeechModel? {
        all.first { $0.id == id }
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(megabytes) * 1_000_000, countStyle: .file)
    }

    var fitsThisDevice: Bool {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 >= minimumMemoryGB
    }

    var folderName: String {
        id.replacingOccurrences(of: "/", with: "--")
    }
}

nonisolated enum SpeechSettings {
    static let languageKey = "speech.language"
    static let engineKey = "speech.engine"
    static let modelKey = "speech.model"

    static var language: SpeechLanguage {
        get { SpeechLanguage(rawValue: UserDefaults.standard.string(forKey: languageKey) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: languageKey) }
    }

    /// An earlier version's "whisper" reads as Apple's: Whisper is gone.
    static var engine: SpeechEngineKind {
        get { SpeechEngineKind(rawValue: UserDefaults.standard.string(forKey: engineKey) ?? "") ?? .apple }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: engineKey) }
    }

    static var model: SpeechModel {
        get { SpeechModel.find(UserDefaults.standard.string(forKey: modelKey) ?? "") ?? .qwen3_0_6b }
        set { UserDefaults.standard.set(newValue.id, forKey: modelKey) }
    }
}
