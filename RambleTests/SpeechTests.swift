import AVFAudio
import Foundation
import FoundationModels
import MLXFoundationModels
import Testing
@testable import Ramble

struct SpeechSettingsTests {
    @Test func followingTheSystemPicksChineseUnlessItsEnglish() {
        #expect(SpeechLanguage.system.resolved(systemLanguage: .english) == .english)
        #expect(SpeechLanguage.system.resolved(systemLanguage: .chinese) == .chinese)
        #expect(SpeechLanguage.system.resolved(systemLanguage: .japanese) == .chinese)
        #expect(SpeechLanguage.english.resolved(systemLanguage: .chinese) == .english)
        #expect(SpeechLanguage.chinese.modelLanguage == "Chinese")
        #expect(SpeechLanguage.english.modelLanguage == "English")
        #expect(SpeechLanguage.chinese.locale.identifier == "zh-CN")
        #expect(SpeechLanguage.english.locale.identifier == "en-US")
    }

    @Test func settingsPersistAndDefaultSensibly() {
        let defaults = UserDefaults.standard
        let keys = [SpeechSettings.languageKey, SpeechSettings.engineKey, SpeechSettings.modelKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        keys.forEach(defaults.removeObject)

        #expect(SpeechSettings.language == .system)
        #expect(SpeechSettings.engine == .apple)
        #expect(SpeechSettings.model == .qwen3_0_6b)

        SpeechSettings.language = .english
        SpeechSettings.engine = .qwen
        SpeechSettings.model = .qwen3_1_7b
        #expect(SpeechSettings.language == .english)
        #expect(SpeechSettings.engine == .qwen)
        #expect(SpeechSettings.model == .qwen3_1_7b)

        defaults.set("gone-model", forKey: SpeechSettings.modelKey)
        #expect(SpeechSettings.model == .qwen3_0_6b)
    }

    /// Whisper is gone: someone who had picked it records with Apple's recognizer until they download Qwen3-ASR.
    @MainActor
    @Test func anEarlierWhisperSettingFallsBackToApple() {
        let defaults = UserDefaults(suiteName: "speech-\(UUID().uuidString)")!
        defaults.set("whisper", forKey: SpeechSettings.engineKey)
        LegacyWhisperFiles.migrateSetting(defaults)
        #expect(defaults.string(forKey: SpeechSettings.engineKey) == SpeechEngineKind.apple.rawValue)

        defaults.set(SpeechEngineKind.qwen.rawValue, forKey: SpeechSettings.engineKey)
        LegacyWhisperFiles.migrateSetting(defaults)
        #expect(defaults.string(forKey: SpeechSettings.engineKey) == SpeechEngineKind.qwen.rawValue)
    }

    @Test func modelsAreTheQwenSpeechBuilds() {
        #expect(SpeechModel.all.allSatisfy { $0.id.hasPrefix("mlx-community/Qwen3-ASR-") })
        #expect(SpeechModel.find(SpeechModel.qwen3_1_7b.id) == .qwen3_1_7b)
        #expect(SpeechModel.qwen3_0_6b.sizeText.contains("GB") || SpeechModel.qwen3_0_6b.sizeText.contains("MB"))
        #expect(SpeechModel.qwen3_0_6b.folderName == "mlx-community--Qwen3-ASR-0.6B-8bit")
    }

    @Test func aModelThatWasNeverCheckedIsntReady() {
        let model = SpeechModel(id: "never/downloaded", title: "", megabytes: 1, minimumMemoryGB: 0, note: "")
        #expect(SpeechModelStore.readyFolder(for: model) == nil)
    }
}

struct SpeechModelOutputTests {
    @Test func chineseComesOutSimplified() {
        let text = SpeechModelEngine.cleaned(" 明天下午三點去醫院複查血脂，順便帶上體檢報告。\n", language: .chinese)
        #expect(text == "明天下午三点去医院复查血脂，顺便带上体检报告。")
    }

    @Test func chineseGetsFullWidthPunctuationButNumbersKeepTheirs() {
        #expect(SpeechModelEngine.cleaned("明天下午3点要去医院复查血脂,然后把报告带上?", language: .chinese)
            == "明天下午3点要去医院复查血脂，然后把报告带上？")
        #expect(SpeechModelEngine.fullWidthPunctuation("3:30 开会,带上1,000元?") == "3:30 开会，带上1,000元？")
        #expect(SpeechModelEngine.cleaned("Call me, OK?", language: .english) == "Call me, OK?")
    }

    @Test func samplesAccumulateFromBuffers() throws {
        let buffer = SampleBuffer()
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: SampleBuffer.format, frameCapacity: 160))
        pcm.frameLength = 160
        for index in 0..<160 { pcm.floatChannelData![0][index] = Float(index) / 160 }
        buffer.append(pcm)
        buffer.append(pcm)
        #expect(buffer.count == 320)
        #expect(buffer.snapshot()[161] == Float(1) / 160)
    }
}

/// Downloads a speech model on the phone (about 1 GB) and transcribes the clips in Fixtures:
/// spoken by the system voices, clean (c) and with background noise (n). Off by default; run on
/// a device with TEST_RUNNER_RAMBLE_SPEECH_MODEL=<repository>, optionally
/// TEST_RUNNER_RAMBLE_SPEECH_REPORT=<file name in Documents>.
struct SpeechModelEndToEndTests {
    nonisolated static let environment = ProcessInfo.processInfo.environment
    static let clips = ["c0", "c1", "c2", "c3", "c4", "c5", "n0", "n1", "n2", "n3", "n4", "n5"]

    @MainActor
    @Test(.enabled(if: environment["RAMBLE_SPEECH_MODEL"] != nil), .timeLimit(.minutes(30)))
    func transcribesTheClips() async throws {
        let model = try #require(SpeechModel.find(Self.environment["RAMBLE_SPEECH_MODEL"] ?? ""))
        let store = SpeechModelStore.shared
        let downloadStarted = ContinuousClock.now
        if SpeechModelStore.readyFolder(for: model) == nil {
            store.download(model)
            while true {
                try await Task.sleep(for: .seconds(2))
                switch store.status(of: model) {
                case .ready: break
                case .failed(let message): Issue.record("download failed: \(message)"); return
                default: continue
                }
                break
            }
        }
        let folder = try #require(SpeechModelStore.readyFolder(for: model))
        var report = "MODEL \(model.id)\nDOWNLOAD+CHECK \(ContinuousClock.now - downloadStarted)\n"

        let engine = SpeechModelEngine.shared
        await engine.unload()
        let loadStarted = ContinuousClock.now
        try await engine.prepare(folder: folder)
        report += "LOAD \(ContinuousClock.now - loadStarted)\n"
        for name in Self.clips {
            let samples = try Self.samples(of: "speech-\(name)")
            let started = ContinuousClock.now
            let text = try await engine.transcribe(samples, language: .chinese)
            let seconds = Double(samples.count) / Double(SampleBuffer.sampleRate)
            report += "\(name) audio \(String(format: "%.1f", seconds))s took \(ContinuousClock.now - started): \(text)\n"
            #expect(!text.isEmpty, "\(name)")
            #expect(text.contains("，") || text.contains("。"), "\(name) has no punctuation: \(text)")
        }

        // The capture sheet loads the AI model while the person talks: both on the GPU at once.
        if #available(iOS 27.0, *), LocalAI.supportsOpenModels,
           let open = OpenModel.all.first(where: { OpenModelStore.readyFolder(for: $0) != nil }),
           let openFolder = OpenModelStore.readyFolder(for: open) {
            let language = OpenModelRuntime.languageModel(open, folder: openFolder)
            let llm = Task.detached {
                try await language.preload()
                let reply = try await LanguageModelSession(model: language)
                    .respond(to: "用一句话介绍北京。", options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 60))
                return reply.content
            }
            for name in Self.clips.prefix(4) {
                let samples = try Self.samples(of: "speech-\(name)")
                let started = ContinuousClock.now
                let text = try await engine.transcribe(samples, language: .chinese)
                report += "WITH \(open.title) \(name) took \(ContinuousClock.now - started): \(text)\n"
                #expect(!text.isEmpty)
            }
            let reply = try await llm.value
            report += "\(open.title) said: \(reply)\n"
            #expect(!reply.isEmpty)
            await LocalAI.releaseMemory()
        }
        print(report)
        if let name = Self.environment["RAMBLE_SPEECH_REPORT"] {
            try? report.write(to: URL.documentsDirectory.appending(path: name), atomically: true, encoding: .utf8)
        }
        await engine.unload()
    }

    /// A clip from the test bundle as 16 kHz mono samples.
    static func samples(of name: String) throws -> [Float] {
        let url = try #require(Bundle(for: SpeechFixtureBundle.self).url(forResource: name, withExtension: "wav"))
        let file = try AVAudioFile(forReading: url)
        #expect(file.processingFormat.sampleRate == Double(SampleBuffer.sampleRate) && file.processingFormat.channelCount == 1)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}

private final class SpeechFixtureBundle {}

/// The live preview of a long recording keeps finished parts instead of re-reading everything.
struct PreviewSegmentsTests {
    private let rate = SampleBuffer.sampleRate

    /// Speech-like signal with a half-second pause starting at `pause` seconds.
    private func recording(seconds: Double, pause: Double) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { i in
            let t = Double(i) / Double(rate)
            return t >= pause && t < pause + 0.5 ? 0 : Float(sin(t * 2 * .pi * 220) * 0.4)
        }
    }

    @Test func shortRecordingsAreReadWhole() {
        #expect(PreviewSegments.cut(in: recording(seconds: 20, pause: 15)) == nil)
    }

    @Test func longRecordingIsCutInThePause() throws {
        let cut = try #require(PreviewSegments.cut(in: recording(seconds: 30, pause: 17)))
        let seconds = Double(cut) / Double(rate)
        #expect(seconds > 17 && seconds < 17.5)
    }

    /// Talk without a break still gets cut, within the window, so the preview never stalls.
    @Test func cutStaysInTheWindowWithoutAPause() throws {
        let cut = try #require(PreviewSegments.cut(in: recording(seconds: 40, pause: 100)))
        #expect(cut >= PreviewSegments.minimum && cut <= PreviewSegments.maximum)
    }

    @Test func keptPartsJoinTheRest() {
        var segments = PreviewSegments()
        segments.keep("明天去超市买菜", samples: 16 * rate)
        segments.keep("顺便取快递。", samples: 14 * rate)
        #expect(segments.start == 30 * rate)
        #expect(segments.joined(with: "晚上给妈妈打电话") == "明天去超市买菜，顺便取快递。晚上给妈妈打电话")
        #expect(PreviewSegments().joined(with: "hello") == "hello")
    }

    @Test func snapshotFromAnOffset() throws {
        let buffer = SampleBuffer()
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: SampleBuffer.format, frameCapacity: 4))
        pcm.frameLength = 4
        for i in 0..<4 { pcm.floatChannelData![0][i] = Float(i) }
        buffer.append(pcm)
        #expect(buffer.snapshot(from: 2) == [2, 3])
        #expect(buffer.snapshot(from: 9).isEmpty)
    }
}
