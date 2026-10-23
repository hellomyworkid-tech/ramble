import Foundation
import FoundationModels
import HuggingFace
import MLXFoundationModels
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Observation
import Tokenizers
import UIKit

/// An open-weight model that runs on the phone through MLX (Apple's machine-learning framework).
/// Weights come from the mlx-community builds on Hugging Face; all of these are Apache 2.0.
nonisolated struct OpenModel: Identifiable, Equatable, Sendable {
    /// Hugging Face repository.
    let id: String
    let title: String
    let megabytes: Int
    /// Phones with less memory can't hold the model next to the app (iOS reports a little under the label).
    let minimumMemoryGB: Double
    let note: LocalizedStringResource
    /// Characters of a document it can take in one go, leaving room for the instructions and answer.
    let characterBudget: Int

    static let qwen3_4b = OpenModel(
        id: "mlx-community/Qwen3-4B-Instruct-2507-4bit", title: "Qwen3 4B", megabytes: 2_279, minimumMemoryGB: 7.2,
        note: "通义千问，整理效果最好，中文和中英混说都很好。需要 8GB 内存的机型：iPhone 15 Pro、iPhone 16 全系及以后。",
        characterBudget: 8_000)
    static let qwen3_1_7b = OpenModel(
        id: "mlx-community/Qwen3-1.7B-4bit", title: "Qwen3 1.7B", megabytes: 984, minimumMemoryGB: 5.5,
        note: "更小更快，给 iPhone 15 等 6GB 内存的机型用。明显不如 4B 准：偶尔会漏记、记错金额，建议配合「自动」模式，本机没记好时再交给云端。",
        characterBudget: 6_000)

    static let all = [qwen3_4b, qwen3_1_7b]

    static func find(_ id: String) -> OpenModel? {
        all.first { $0.id == id }
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(megabytes) * 1_000_000, countStyle: .file)
    }

    /// Whether this phone has enough memory for it.
    var fitsThisDevice: Bool {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 >= minimumMemoryGB
    }

    var folderName: String {
        id.replacingOccurrences(of: "/", with: "--")
    }
}

/// Downloads and removes open models, and tracks where each one is.
@Observable
final class OpenModelStore {
    static let shared = OpenModelStore()

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
    /// Listing a repository's files, or checking a finished download.
    private var tasks: [String: Task<Void, Never>] = [:]
    private var observer: NSObjectProtocol?

    nonisolated private static let readyMarker = ".ramble-ready"

    init() {
        observer = NotificationCenter.default.addObserver(forName: BackgroundDownloads.didChange, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let job = note.object as? String, let model = OpenModel.all.first(where: { Self.job($0) == job }) else { return }
                self?.refresh(model)
            }
        }
        refresh()
    }

    /// Application Support/OpenModels, kept out of iCloud backups (it can be downloaded again).
    nonisolated static var baseFolder: URL {
        var url = URL.applicationSupportDirectory.appending(path: "OpenModels", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    nonisolated static func folder(for model: OpenModel) -> URL {
        baseFolder.appending(path: model.folderName, directoryHint: .isDirectory)
    }

    /// The model's folder, once it's downloaded and checked.
    nonisolated static func readyFolder(for model: OpenModel) -> URL? {
        let folder = folder(for: model)
        return FileManager.default.fileExists(atPath: folder.appending(path: readyMarker).path) ? folder : nil
    }

    private static func job(_ model: OpenModel) -> String { "open:" + model.id }

    func status(of model: OpenModel) -> Status {
        statuses[model.id] ?? .notDownloaded
    }

    func refresh() {
        OpenModel.all.forEach(refresh)
    }

    private func refresh(_ model: OpenModel) {
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

    func download(_ model: OpenModel) {
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

    /// Loads the downloaded model once to catch a missing or broken file, then frees the memory.
    /// Waits for the app to be in front: a couple of GB shouldn't load while iOS has it in the background.
    private func check(_ model: OpenModel) {
        guard UIApplication.shared.applicationState == .active else {
            statuses[model.id] = .checking
            return
        }
        statuses[model.id] = .checking
        tasks[model.id] = Task {
            do {
                let folder = Self.folder(for: model)
                if #available(iOS 27.0, *), LocalAI.supportsOpenModels {
                    let language = OpenModelRuntime.languageModel(model, folder: folder)
                    try await language.preload()
                    await language.evict()
                }
                FileManager.default.createFile(atPath: folder.appending(path: Self.readyMarker).path, contents: Data())
                BackgroundDownloads.shared.forget(job: Self.job(model))
                statuses[model.id] = .ready
            } catch {
                statuses[model.id] = .failed(error.localizedDescription)
            }
            tasks[model.id] = nil
        }
    }

    func cancel(_ model: OpenModel) {
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
        BackgroundDownloads.shared.cancel(job: Self.job(model))
        try? FileManager.default.removeItem(at: Self.folder(for: model))
        statuses[model.id] = .notDownloaded
        diskBytes[model.id] = 0
    }

    /// Removes the model's files, whole or partly downloaded. Captures then use whatever else is
    /// set up: Apple's model or the cloud.
    func delete(_ model: OpenModel) {
        cancel(model)
        Task { await LocalAI.releaseMemory() }
    }

    /// What deleting frees: the files on disk, or the download size before they've been measured.
    func freedText(_ model: OpenModel) -> String {
        let bytes = diskBytes[model.id] ?? 0
        return bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : model.sizeText
    }

    /// Whether files are on disk with no download or check running, so they can be deleted.
    func canDelete(_ model: OpenModel) -> Bool {
        switch status(of: model) {
        case .downloading, .checking: false
        default: (diskBytes[model.id] ?? 0) > 0
        }
    }
}

nonisolated enum OpenModelError: LocalizedError {
    case badRepository
    var errorDescription: String? { String(localized: "模型地址不对。") }
}

/// Builds the FoundationModels-compatible wrapper around a downloaded model. Guided generation
/// constrains the output to the requested `@Generable` type, so a small model can't wander off
/// into prose or invalid JSON.
@available(iOS 27.0, *)
nonisolated enum OpenModelRuntime {
    static func languageModel(_ model: OpenModel, folder: URL) -> MLXLanguageModel {
        MLXLanguageModel(
            configuration: ModelConfiguration(directory: folder, extraEOSTokens: ["<|im_end|>"]),
            capabilities: [.guidedGeneration],
            weightsLocation: { _ in folder },
            load: { _, _ in
                try await loadModelContainer(from: folder, using: #huggingFaceTokenizerLoader())
            })
    }
}
