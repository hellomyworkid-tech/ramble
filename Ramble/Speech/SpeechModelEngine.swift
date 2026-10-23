import Foundation
import MLX
import MLXAudioSTT
import Observation
import UIKit

/// Runs a downloaded Qwen3-ASR model on the phone's GPU through MLX. One model stays loaded
/// between recordings (loading takes a second or two); calls run one at a time.
actor SpeechModelEngine {
    static let shared = SpeechModelEngine()

    enum EngineError: LocalizedError {
        case notLoaded
        var errorDescription: String? { String(localized: "语音模型还没准备好。") }
    }

    /// MLX needs the phone's GPU; the simulator has none it can use.
    nonisolated static var isSupported: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    private var model: Qwen3ASRModel?
    private var loadedFolder: URL?
    /// A load in progress, so a second caller waits for it instead of loading again.
    private var loading: (folder: URL, task: Task<LoadedModel, Error>)?

    /// The loaded model, handed from the loading task to this actor.
    private struct LoadedModel: @unchecked Sendable {
        let model: Qwen3ASRModel
    }

    /// Loads the model in `folder`. Cheap when it's already the loaded one.
    func prepare(folder: URL) async throws {
        if loadedFolder == folder, model != nil { return }
        if let loading, loading.folder == folder {
            _ = try await loading.task.value
            return
        }
        unload()
        let task = Task { LoadedModel(model: try await Qwen3ASRModel.fromModelDirectory(folder)) }
        loading = (folder, task)
        defer { if loading?.folder == folder { loading = nil } }
        let loaded = try await task.value
        model = loaded.model
        loadedFolder = folder
    }

    func unload() {
        model = nil
        loadedFolder = nil
        Memory.clearCache()
    }

    /// 16 kHz mono samples → text with punctuation.
    func transcribe(_ samples: [Float], language: SpeechLanguage) throws -> String {
        guard let model else { throw EngineError.notLoaded }
        let seconds = Double(samples.count) / Double(SampleBuffer.sampleRate)
        // About 5 characters a second is fast speech; the cap stops a rare repetition loop.
        let output = model.generate(audio: MLXArray(samples), maxTokens: Int(seconds * 12) + 40,
                                    language: language.modelLanguage)
        Memory.clearCache()
        return Self.cleaned(output.text, language: language)
    }

    nonisolated static func cleaned(_ text: String, language: SpeechLanguage) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if language.resolved() == .chinese {
            // Cantonese and some dialects come out in traditional characters.
            text = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
            text = fullWidthPunctuation(text)
        }
        return text
    }

    /// Chinese with ASCII commas and question marks gets full-width ones; numbers like 3:30 and 1,000 keep theirs.
    nonisolated static func fullWidthPunctuation(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![0-9])[,;:!?]|[,;:!?](?![0-9])"#) else { return text }
        let map: [String: String] = [",": "，", ";": "；", ":": "：", "!": "！", "?": "？"]
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: map[String(result[range])] ?? String(result[range]))
        }
        return result
    }
}

/// Downloads, checks and removes speech models, and tracks where each one is.
@Observable
final class SpeechModelStore {
    static let shared = SpeechModelStore()

    enum Status: Equatable {
        case notDownloaded
        case downloading(Double)
        /// Downloaded; loading it once to make sure it runs on this phone.
        case checking
        case ready
        case failed(String)
    }

    private(set) var statuses: [String: Status] = [:]
    /// Space each model's files take, whole or partly downloaded.
    private(set) var diskBytes: [String: Int64] = [:]
    /// What an earlier version's Whisper download left behind.
    private(set) var legacyBytes: Int64 = 0
    /// Listing a repository's files, or checking a finished download.
    private var tasks: [String: Task<Void, Never>] = [:]
    private var observer: NSObjectProtocol?

    nonisolated private static let readyMarker = ".ramble-ready"

    init() {
        observer = NotificationCenter.default.addObserver(forName: BackgroundDownloads.didChange, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let job = note.object as? String, let model = SpeechModel.all.first(where: { Self.job($0) == job }) else { return }
                self?.refresh(model)
            }
        }
        refresh()
    }

    /// Application Support/SpeechModels, kept out of iCloud backups (it can be downloaded again).
    nonisolated static var baseFolder: URL {
        var url = URL.applicationSupportDirectory.appending(path: "SpeechModels", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    nonisolated static func folder(for model: SpeechModel) -> URL {
        baseFolder.appending(path: model.folderName, directoryHint: .isDirectory)
    }

    /// The model's folder, once it's downloaded and checked.
    nonisolated static func readyFolder(for model: SpeechModel) -> URL? {
        let folder = folder(for: model)
        return FileManager.default.fileExists(atPath: folder.appending(path: readyMarker).path) ? folder : nil
    }

    private static func job(_ model: SpeechModel) -> String { "speech:" + model.id }

    func status(of model: SpeechModel) -> Status {
        statuses[model.id] ?? .notDownloaded
    }

    func refresh() {
        SpeechModel.all.forEach(refresh)
        legacyBytes = FileManager.default.allocatedBytes(in: LegacyWhisperFiles.folder)
    }

    private func refresh(_ model: SpeechModel) {
        guard tasks[model.id] == nil else { return }
        diskBytes[model.id] = FileManager.default.allocatedBytes(in: Self.folder(for: model))
        if Self.readyFolder(for: model) != nil {
            statuses[model.id] = .ready
            return
        }
        switch BackgroundDownloads.shared.state(of: Self.job(model)) {
        case .none: statuses[model.id] = .notDownloaded
        case .running(let fraction): statuses[model.id] = .downloading(fraction)
        case .failed(let message): statuses[model.id] = .failed(message)
        case .finished: check(model)
        }
    }

    func download(_ model: SpeechModel) {
        guard tasks[model.id] == nil else { return }
        let free = (try? URL.applicationSupportDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        guard free > Int64(model.megabytes) * 1_300_000 else {
            statuses[model.id] = .failed(String(localized: "存储空间不够，需要约 \(model.sizeText)，再留一些余量。"))
            return
        }
        statuses[model.id] = .downloading(0)
        tasks[model.id] = Task {
            do {
                let files = try await HuggingFaceFiles.list(repo: model.id)
                // The system downloads in the background from here, screen off or app closed.
                BackgroundDownloads.shared.start(job: Self.job(model), folder: Self.folder(for: model), files: files)
            } catch {
                statuses[model.id] = .failed(error.localizedDescription)
            }
            tasks[model.id] = nil
        }
    }

    /// Loads the downloaded model and transcribes a moment of silence, to catch a missing or broken
    /// file before the person relies on it. Waits for the app to be in front.
    private func check(_ model: SpeechModel) {
        guard UIApplication.shared.applicationState == .active else {
            statuses[model.id] = .checking
            return
        }
        statuses[model.id] = .checking
        tasks[model.id] = Task {
            do {
                let folder = Self.folder(for: model)
                if SpeechModelEngine.isSupported {
                    let engine = SpeechModelEngine.shared
                    try await engine.prepare(folder: folder)
                    _ = try await engine.transcribe([Float](repeating: 0, count: SampleBuffer.sampleRate), language: .chinese)
                    await engine.unload()
                }
                FileManager.default.createFile(atPath: folder.appending(path: Self.readyMarker).path, contents: Data())
                BackgroundDownloads.shared.forget(job: Self.job(model))
                diskBytes[model.id] = FileManager.default.allocatedBytes(in: folder)
                statuses[model.id] = .ready
            } catch {
                statuses[model.id] = .failed(error.localizedDescription)
            }
            tasks[model.id] = nil
        }
    }

    func cancel(_ model: SpeechModel) {
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
        BackgroundDownloads.shared.cancel(job: Self.job(model))
        try? FileManager.default.removeItem(at: Self.folder(for: model))
        statuses[model.id] = .notDownloaded
        diskBytes[model.id] = 0
    }

    /// Removes the model's files, whole or partly downloaded. Recording then uses Apple's recognizer.
    func delete(_ model: SpeechModel) {
        cancel(model)
        Task { await SpeechModelEngine.shared.unload() }
    }

    func deleteLegacyWhisper() {
        LegacyWhisperFiles.delete()
        legacyBytes = 0
    }

    /// What deleting frees: the files on disk, or the download size before they've been measured.
    func freedText(_ model: SpeechModel) -> String {
        let bytes = diskBytes[model.id] ?? 0
        return bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : model.sizeText
    }

    /// Whether files are on disk with no download or check running, so they can be deleted.
    func canDelete(_ model: SpeechModel) -> Bool {
        switch status(of: model) {
        case .downloading, .checking: false
        default: (diskBytes[model.id] ?? 0) > 0
        }
    }
}

/// Earlier versions offered Whisper; its models (627 MB or 217 MB) stay on the phone until removed.
enum LegacyWhisperFiles {
    nonisolated static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "WhisperModels", directoryHint: .isDirectory)
    }

    private static let variants = ["openai_whisper-large-v3-v20240930_626MB", "openai_whisper-small_216MB"]

    static func delete() {
        for variant in variants {
            BackgroundDownloads.shared.cancel(job: "whisper:" + variant)
            UserDefaults.standard.removeObject(forKey: "speech.whisperFolder." + variant)
        }
        UserDefaults.standard.removeObject(forKey: "speech.whisperModel")
        try? FileManager.default.removeItem(at: folder)
    }

    /// Someone who picked Whisper gets Apple's recognizer until they download Qwen3-ASR.
    static func migrateSetting(_ defaults: UserDefaults = .standard) {
        if defaults.string(forKey: SpeechSettings.engineKey) == "whisper" {
            defaults.set(SpeechEngineKind.apple.rawValue, forKey: SpeechSettings.engineKey)
        }
    }
}
