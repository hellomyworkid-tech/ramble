import Foundation
import FoundationModels
import MLXFoundationModels

/// Which model runs on the phone.
nonisolated enum LocalEngine: String, CaseIterable, Identifiable {
    /// Apple Intelligence: nothing to download, but small and weak at Chinese tidying.
    case apple
    /// A downloaded open model (Qwen) through MLX. Needs iOS 27.
    case open

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .apple: "Apple Intelligence"
        case .open: "开源模型（通义千问）"
        }
    }
}

/// The on-device side of AI: picks Apple's model or a downloaded open one and hands out
/// sessions for it, so callers don't care which it is.
nonisolated enum LocalAI {
    static let engineKey = "ai.localEngine"
    static let openModelKey = "ai.openModel"

    static var engine: LocalEngine {
        LocalEngine(rawValue: UserDefaults.standard.string(forKey: engineKey) ?? "") ?? .apple
    }

    static var openModel: OpenModel {
        OpenModel.find(UserDefaults.standard.string(forKey: openModelKey) ?? "") ?? .qwen3_4b
    }

    /// iOS 27 on a real device: MLX needs the GPU's architecture name, which the simulator leaves empty.
    static var supportsOpenModels: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        if #available(iOS 27.0, *) { return true }
        return false
        #endif
    }

    static var status: OnDeviceStatus {
        switch engine {
        case .apple:
            return OnDeviceParser.status
        case .open:
            guard supportsOpenModels else { return isSimulator ? .unknown : .needsNewerSystem }
            let model = openModel
            guard model.fitsThisDevice else { return .notEnoughMemory }
            return OpenModelStore.readyFolder(for: model) == nil ? .modelNotDownloaded : .available
        }
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// Shown on results: which model did the work.
    static var displayName: String {
        engine == .open ? openModel.title : String(localized: "本机")
    }

    /// How much document text the on-device model can take at once.
    static var characterBudget: Int {
        engine == .open && status.isAvailable ? openModel.characterBudget : 1_500
    }

    /// Whether requests go to a downloaded open model (and so use the lean output types).
    static var usesOpenModel: Bool {
        engine == .open && supportsOpenModels && OpenModelStore.readyFolder(for: openModel) != nil
    }

    /// Loads the open model's weights ahead of the first request (a few seconds), while the person
    /// is still talking. Does nothing for Apple's model, which the system manages.
    static func prepare() {
        guard #available(iOS 27.0, *), usesOpenModel, let folder = OpenModelStore.readyFolder(for: openModel) else { return }
        let model = OpenModelRuntime.languageModel(openModel, folder: folder)
        Task.detached(priority: .utility) {
            await releaseSpeechModelIfIdle()
            try? await model.preload()
            // Loaded ahead and then not used (the person never tapped 整理): let it go too.
            await ModelIdleRelease.languageModelIdle(endingUse: false)
        }
    }

    /// When the microphone starts: loads ahead only if speech doesn't use a model of its own.
    /// The speech model (about 1 GB) and Qwen3 4B (about 2.3 GB) together left an 8 GB iPhone
    /// with almost no free memory: other apps were killed and the swipe home stuttered.
    @MainActor static func prepareWhileListening() {
        guard !SpeechRecorder.usesSpeechModel else { return }
        prepare()
    }

    /// A session on the chosen model.
    static func makeSession(instructions: String) -> LanguageModelSession {
        if #available(iOS 27.0, *), usesOpenModel, let folder = OpenModelStore.readyFolder(for: openModel) {
            Task { await releaseSpeechModelIfIdle() }
            return LanguageModelSession(model: OpenModelRuntime.languageModel(openModel, folder: folder), instructions: instructions)
        }
        return LanguageModelSession(instructions: instructions)
    }

    /// Frees the speech model before an open model loads, unless a recording is using it.
    private static func releaseSpeechModelIfIdle() async {
        guard await SpeechRecorder.modelRecordings == 0 else { return }
        await SpeechModelEngine.shared.unload()
    }

    /// Open models answer more reliably without sampling randomness; Apple's keeps its defaults.
    /// Greedy decoding for open models, with a cap on the answer. Guided generation lets a small
    /// model write whitespace without end, and the library only steers it to close the JSON as it
    /// nears the cap: at the default 4,096 tokens that took Qwen3 1.7B three and a half minutes.
    /// A retry (「重新整理」) samples instead, with a different seed each time: greedy decoding
    /// would only give the same answer again.
    static func options(maximumTokens: Int, attempt: AIAttempt = .first) -> GenerationOptions {
        // Open models only run on iOS 27, where the sampling option has its new name.
        if #available(iOS 27.0, *), engine == .open {
            let sampling: GenerationOptions.SamplingMode = attempt.isRetry ? .random(top: 40, seed: UInt64(attempt.number)) : .greedy
            return GenerationOptions(samplingMode: sampling, temperature: attempt.isRetry ? 0.6 : nil,
                                     maximumResponseTokens: min(maximumTokens, 4096))
        }
        return GenerationOptions()
    }

    /// Room for a tidied passage (about a token per character) and its reminders.
    static func organizeOptions(for text: String, attempt: AIAttempt = .first) -> GenerationOptions {
        options(maximumTokens: 160 + text.count * 2, attempt: attempt)
    }

    /// Room for the records in a capture: each takes 40 or so tokens, about one per dozen characters said.
    static func captureOptions(for text: String, attempt: AIAttempt = .first) -> GenerationOptions {
        options(maximumTokens: 160 + text.count * 3, attempt: attempt)
    }

    /// Frees an open model's memory (it can be a couple of GB); it reloads on next use.
    static func releaseMemory() async {
        if #available(iOS 27.0, *) {
            await MLXLanguageModel.evictAll()
        }
    }
}
