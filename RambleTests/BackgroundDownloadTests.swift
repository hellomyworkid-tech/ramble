import Foundation
import Testing
@testable import Ramble

struct BackgroundDownloadUnitTests {
    @Test func taskDescriptionsRoundTrip() {
        #expect(BackgroundDownloads.parse("open:mlx-community/Qwen3-4B\nmodel.safetensors")! == ("open:mlx-community/Qwen3-4B", "model.safetensors"))
        #expect(BackgroundDownloads.parse("speech:x\nfolder/sub/weight.bin")?.path == "folder/sub/weight.bin")
        #expect(BackgroundDownloads.parse("no separator") == nil)
        #expect(BackgroundDownloads.parse(nil) == nil)
    }

    @Test func aFileIsCompleteOnlyAtItsFullSize() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appending(path: "sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(count: 10).write(to: folder.appending(path: "sub/a.bin"))
        let url = URL(string: "https://example.com/a.bin")!
        #expect(BackgroundDownloads.isComplete(RemoteFile(path: "sub/a.bin", size: 10, url: url), in: folder))
        #expect(!BackgroundDownloads.isComplete(RemoteFile(path: "sub/a.bin", size: 11, url: url), in: folder))
        #expect(!BackgroundDownloads.isComplete(RemoteFile(path: "sub/missing.bin", size: 10, url: url), in: folder))
    }
}

/// Real downloads from Hugging Face through the background session (small files only).
/// Off by default; run with TEST_RUNNER_RAMBLE_NETWORK_TESTS=1.
struct BackgroundDownloadNetworkTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["RAMBLE_NETWORK_TESTS"] != nil

    @Test(.enabled(if: enabled), .timeLimit(.minutes(5)))
    func listsRepositoriesAndFolders() async throws {
        let qwen = try await HuggingFaceFiles.list(repo: "mlx-community/Qwen3-1.7B-4bit")
        #expect(qwen.contains { $0.path == "config.json" })
        #expect(qwen.contains { $0.path.hasSuffix(".safetensors") && $0.size > 500_000_000 })

        // The sizes the speech settings show match what's published.
        for model in SpeechModel.all {
            let files = try await HuggingFaceFiles.list(repo: model.id)
            #expect(files.contains { $0.path == "config.json" } && files.contains { $0.path == "vocab.json" })
            let megabytes = files.reduce(Int64(0)) { $0 + $1.size } / 1_000_000
            #expect(abs(Int(megabytes) - model.megabytes) < 20, "\(model.id): \(megabytes) MB")
        }
    }

    @MainActor
    @Test(.enabled(if: enabled), .timeLimit(.minutes(5)))
    func downloadsFilesInTheBackgroundSession() async throws {
        let files = try await HuggingFaceFiles.list(repo: "mlx-community/Qwen3-1.7B-4bit")
            .filter { $0.size < 5_000_000 }
        #expect(files.count >= 4)
        let folder = FileManager.default.temporaryDirectory.appending(path: "download-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let job = "test:\(UUID().uuidString)"
        let downloads = BackgroundDownloads.shared
        downloads.start(job: job, folder: folder, files: files)

        var state = downloads.state(of: job)
        for _ in 0..<240 {
            if state == .finished { break }
            if case .failed(let message) = state { Issue.record("failed: \(message)"); break }
            try await Task.sleep(for: .milliseconds(500))
            state = downloads.state(of: job)
        }
        #expect(state == .finished)
        for file in files {
            #expect(BackgroundDownloads.isComplete(file, in: folder), "\(file.path)")
        }
        // Real JSON, not an error page.
        let config = try Data(contentsOf: folder.appending(path: "config.json"))
        #expect((try JSONSerialization.jsonObject(with: config) as? [String: Any])?["model_type"] as? String == "qwen3")

        downloads.forget(job: job)
        #expect(downloads.state(of: job) == .none)
    }
}
