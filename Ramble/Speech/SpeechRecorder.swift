import AVFAudio
import Observation
import OSLog
import Speech
import UIKit

/// Live, on-device speech-to-text. Text streams in while the person talks;
/// nothing leaves the phone at this stage. Uses Apple's recognizer, or a downloaded
/// Qwen3-ASR model when the person picked one in settings.
@Observable
final class SpeechRecorder {
    enum State: Equatable {
        case idle, preparing, recording, finishing
    }

    enum RecorderError: LocalizedError {
        case microphoneDenied, noMicrophone, unsupportedLocale, noAudioFormat

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: String(localized: "没有麦克风权限。请在「设置 › 随口记」里打开。")
            case .noMicrophone: String(localized: "没有找到可用的麦克风。")
            case .unsupportedLocale: String(localized: "这台设备的语音识别暂不支持当前语言。")
            case .noAudioFormat: String(localized: "语音识别暂时不可用。")
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var finalizedText = ""
    private(set) var volatileText = ""
    /// 0…1, for the level meter.
    private(set) var level: Float = 0
    var errorMessage: String?

    var transcript: String { finalizedText + volatileText }
    var isActive: Bool { state != .idle }

    private var analyzer: SpeechAnalyzer?
    private var audio: AudioCapture?
    private var resultsTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    /// Speech model: the recording so far, and the loop that re-reads it for the live preview.
    private var samples: SampleBuffer?
    private var previewTask: Task<Void, Never>?
    /// The parts of a long recording that have been read and kept, so the preview only re-reads the rest.
    private var segments = PreviewSegments()
    private var modelFolder: URL?
    /// The app went to the background mid-recording; the rest is read once it's back in front.
    private var finishesInForeground = false
    private var keepsScreenOn = false
    private var appObservers: [NSObjectProtocol] = []

    /// Recordings using the speech model right now. A language model loading meanwhile would
    /// have to share memory with it (see `LocalAI.prepareWhileListening`).
    private(set) static var modelRecordings = 0

    /// Whether a recording started now would use the downloaded speech model.
    static var usesSpeechModel: Bool {
        SpeechSettings.engine == .qwen && SpeechModelEngine.isSupported
            && SpeechModelStore.readyFolder(for: SpeechSettings.model).map { $0 != failedFolder } == true
    }
    /// A model that wouldn't load this session; recordings use Apple's recognizer instead.
    private static var failedFolder: URL?

    func start() async {
        guard state == .idle else { return }
        errorMessage = nil
        finalizedText = ""
        volatileText = ""
        segments = PreviewSegments()
        state = .preparing
        // A minute of talking is longer than many people's auto-lock, and a locked phone stops the microphone.
        keepsScreenOn = true
        UIApplication.shared.isIdleTimerDisabled = true
        observeApp()
        do {
            guard await AVAudioApplication.requestRecordPermission() else { throw RecorderError.microphoneDenied }
            if SpeechSettings.engine == .qwen, SpeechModelEngine.isSupported,
               let folder = SpeechModelStore.readyFolder(for: SpeechSettings.model), folder != Self.failedFolder {
                try startModel(folder: folder, language: SpeechSettings.language)
                state = .recording
                return
            }
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: SpeechSettings.language.locale) else {
                throw RecorderError.unsupportedLocale
            }
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw RecorderError.noAudioFormat
            }

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        if result.isFinal {
                            self?.finalizedText += text
                            self?.volatileText = ""
                        } else {
                            self?.volatileText = text
                        }
                    }
                } catch {
                    self?.errorMessage = error.localizedDescription
                }
            }
            try await analyzer.start(inputSequence: stream)
            self.analyzer = analyzer

            let (levels, levelContinuation) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(1))
            levelTask = Task { [weak self] in
                for await level in levels { self?.level = level }
            }
            let audio = AudioCapture(targetFormat: format, onLevel: { levelContinuation.yield($0) },
                                     onBuffer: { continuation.yield(AnalyzerInput(buffer: $0)) },
                                     onFinish: { continuation.finish() },
                                     onInterruption: { [weak self] in Task { await self?.stop() } })
            try audio.start()
            self.audio = audio
            state = .recording
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await teardown()
        }
    }

    /// Stops listening and waits for the last words to be finalized.
    func stop() async {
        guard state == .recording else { return }
        state = .finishing
        audio?.stop()
        if let samples {
            previewTask?.cancel()
            await previewTask?.value
            await finishModel(samples)
        } else {
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            await resultsTask?.value
        }
        await teardown()
    }

    // MARK: Leaving the app

    private func observeApp() {
        guard appObservers.isEmpty else { return }
        let center = NotificationCenter.default
        appObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.enteredBackground() }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.becameActive() }
            },
        ]
    }

    /// The screen locked or the person left mid-recording: the microphone stops there and what was
    /// said is kept. Apple's recognizer finishes now; the speech model can't use the GPU in the
    /// background, so it reads the rest when the app is back in front. (Before, the recording
    /// looked live on return but had stopped, with no way out except tapping stop.)
    private func enteredBackground() {
        guard state == .recording else { return }
        guard samples != nil else {
            Task { await stop() }
            return
        }
        state = .finishing
        audio?.stop()
        previewTask?.cancel()
        finishesInForeground = true
    }

    private func becameActive() {
        guard finishesInForeground, let samples else { return }
        finishesInForeground = false
        Task {
            await previewTask?.value
            await finishModel(samples)
            await teardown()
        }
    }

    func cancel() async {
        audio?.stop()
        previewTask?.cancel()
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        await teardown()
    }

    // MARK: Speech model

    /// Starts listening straight away; the model loads meanwhile (a second or two the first time)
    /// and catches up on what's been said.
    private func startModel(folder: URL, language: SpeechLanguage) throws {
        let buffer = SampleBuffer()
        let (levels, levelContinuation) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(1))
        levelTask = Task { [weak self] in
            for await level in levels { self?.level = level }
        }
        let audio = AudioCapture(targetFormat: SampleBuffer.format, onLevel: { levelContinuation.yield($0) },
                                 onBuffer: { buffer.append($0) }, onFinish: {},
                                 onInterruption: { [weak self] in Task { await self?.stop() } })
        try audio.start()
        self.audio = audio
        samples = buffer
        modelFolder = folder
        Self.modelRecordings += 1
        let engine = SpeechModelEngine.shared
        previewTask = Task { [weak self] in
            // The language model and the speech model don't fit in memory together.
            await LocalAI.releaseMemory()
            do {
                try await engine.prepare(folder: folder)
            } catch {
                await self?.modelFailed(folder: folder, error: error)
                return
            }
            // Re-reads what hasn't been kept yet every so often, so text shows up while the person talks.
            // Once that stretch gets long, its first part (up to a pause) is read one last time and kept:
            // each refresh stays a few seconds' work however long the recording runs. (It used to re-read
            // everything and gave up after a minute, so the text stopped growing until the end.)
            var lastCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1000))
                guard !Task.isCancelled, let self else { break }
                // No GPU work while the app isn't in front: it competes with the system's own
                // animations (the swipe home), and isn't allowed at all in the background.
                guard UIApplication.shared.applicationState == .active else { continue }
                // Reloads the model if it was let go meanwhile (the app went to the background).
                guard (try? await engine.prepare(folder: folder)) != nil else { continue }
                let count = buffer.count
                guard count > SampleBuffer.sampleRate / 2, count != lastCount else { continue }
                lastCount = count
                var open = buffer.snapshot(from: self.segments.start)
                if let cut = PreviewSegments.cut(in: open),
                   let text = try? await engine.transcribe(Array(open[..<cut]), language: language) {
                    self.segments.keep(text, samples: cut)
                    open = Array(open[cut...])
                }
                guard !Task.isCancelled else { break }
                guard open.count > SampleBuffer.sampleRate / 4 else { continue }
                if let text = try? await engine.transcribe(open, language: language), !Task.isCancelled {
                    self.volatileText = self.segments.joined(with: text)
                }
            }
        }
    }

    /// The model wouldn't load (most likely memory): this recording stops, and the next ones use
    /// Apple's recognizer until the app restarts.
    private func modelFailed(folder: URL, error: Error) async {
        Self.log.error("Speech model unavailable: \(error.localizedDescription, privacy: .public)")
        Self.failedFolder = folder
        errorMessage = String(localized: "本机语音模型没能载入，这次没录上。再点一次麦克风，会先用 iPhone 自带的识别。")
        if state == .recording { await teardown() }
    }

    /// The last stretch (the whole recording, when it was short) read once more now that it's complete.
    private func finishModel(_ buffer: SampleBuffer) async {
        let recording = buffer.snapshot(from: segments.start)
        guard recording.count > SampleBuffer.sampleRate / 4 else {
            finalizedText = segments.text
            volatileText = ""
            return
        }
        do {
            if let modelFolder { try await SpeechModelEngine.shared.prepare(folder: modelFolder) }
            let text = try await SpeechModelEngine.shared.transcribe(recording, language: SpeechSettings.language)
            finalizedText = segments.joined(with: text)
            volatileText = ""
        } catch {
            // Keep the preview rather than losing what was said.
            finalizedText = volatileText
            volatileText = ""
            if errorMessage == nil { errorMessage = error.localizedDescription }
        }
    }

    private func teardown() async {
        audio?.stop()
        audio = nil
        analyzer = nil
        resultsTask = nil
        previewTask = nil
        if samples != nil {
            Self.modelRecordings -= 1
            ModelIdleRelease.speechModelIdle()
        }
        samples = nil
        modelFolder = nil
        finishesInForeground = false
        if keepsScreenOn {
            keepsScreenOn = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
        appObservers.forEach(NotificationCenter.default.removeObserver)
        appObservers = []
        levelTask?.cancel()
        levelTask = nil
        level = 0
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static let log = Logger(subsystem: "com.zengji.suikouji", category: "speech")
}

/// The speech model's recording: 16 kHz mono samples, appended from the audio thread.
nonisolated final class SampleBuffer: @unchecked Sendable {
    static let sampleRate = 16_000
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!

    private let lock = NSLock()
    private var samples: [Float] = []

    var count: Int { lock.withLock { samples.count } }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let new = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        lock.withLock { samples.append(contentsOf: new) }
    }

    func snapshot() -> [Float] {
        lock.withLock { samples }
    }

    /// Everything from `start` on.
    func snapshot(from start: Int) -> [Float] {
        lock.withLock { start < samples.count ? Array(samples[start...]) : [] }
    }
}

/// A long live preview in parts: the start of the recording that's been read for good, and its text.
nonisolated struct PreviewSegments: Equatable {
    /// The open stretch is cut once it's longer than this…
    static let maximum = 24 * SampleBuffer.sampleRate
    /// …at the quietest moment at least this far into it.
    static let minimum = 12 * SampleBuffer.sampleRate

    /// First sample not yet kept.
    private(set) var start = 0
    private(set) var text = ""

    mutating func keep(_ part: String, samples count: Int) {
        text = Punctuation.joining(text, part.trimmingCharacters(in: .whitespaces))
        start += count
    }

    func joined(with rest: String) -> String {
        Punctuation.joining(text, rest.trimmingCharacters(in: .whitespaces))
    }

    /// Where to cut `open` (samples from `start` on), or nil while it's short enough: the middle of
    /// the quietest 0.4 s between `minimum` and `maximum`, so the cut falls in a pause.
    static func cut(in open: [Float]) -> Int? {
        guard open.count > maximum else { return nil }
        let block = SampleBuffer.sampleRate / 10
        let blocks = (minimum / block)..<(maximum / block)
        let energy = blocks.map { index in
            open[(index * block)..<((index + 1) * block)].reduce(Float(0)) { $0 + $1 * $1 }
        }
        let width = 4
        guard energy.count >= width else { return minimum }
        var best = 0
        var bestSum = Float.greatestFiniteMagnitude
        var sum = energy[0..<width].reduce(0, +)
        for offset in 0...(energy.count - width) {
            if offset > 0 { sum += energy[offset + width - 1] - energy[offset - 1] }
            if sum < bestSum { bestSum = sum; best = offset }
        }
        return (blocks.lowerBound + best + width / 2) * block
    }
}

/// Microphone → analyzer plumbing. Kept off the main actor because the tap
/// block runs on the audio thread.
nonisolated final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private let onLevel: @Sendable (Float) -> Void
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private let onFinish: @Sendable () -> Void
    /// A phone call, Siri or an alarm took the microphone.
    private let onInterruption: @Sendable () -> Void
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var stopped = false
    private var observers: [NSObjectProtocol] = []

    init(targetFormat: AVAudioFormat, onLevel: @escaping @Sendable (Float) -> Void,
         onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void, onFinish: @escaping @Sendable () -> Void,
         onInterruption: @escaping @Sendable () -> Void = {}) {
        self.targetFormat = targetFormat
        self.onLevel = onLevel
        self.onBuffer = onBuffer
        self.onFinish = onFinish
        self.onInterruption = onInterruption
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        try startEngine()

        // The engine stops by itself when the audio route or format changes (headphones in or
        // out, the keyboard or another app touching the session) and doesn't start again:
        // without this, the transcript would just stop growing mid-recording.
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                queue: nil) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                                                                queue: nil) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw.flatMap(AVAudioSession.InterruptionType.init) == .began { self?.onInterruption() }
        })
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw SpeechRecorder.RecorderError.noMicrophone
        }
        lock.withLock { converter = AVAudioConverter(from: inputFormat, to: targetFormat) }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func restartAfterConfigurationChange() {
        guard !lock.withLock({ stopped }) else { return }
        do {
            try startEngine()
        } catch {
            // No microphone any more: end the recording with what was said.
            onInterruption()
        }
    }

    func stop() {
        let alreadyStopped = lock.withLock { () -> Bool in
            defer { stopped = true }
            return stopped
        }
        guard !alreadyStopped else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        onFinish()
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        onLevel(Self.level(of: buffer))
        guard let converter = lock.withLock({ converter }) else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, output.frameLength > 0 {
            onBuffer(output)
        }
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        let rms = (sum / Float(count)).squareRoot()
        // Map roughly -50 dB…0 dB onto 0…1.
        let decibels = 20 * log10(max(rms, 0.000_01))
        return max(0, min(1, (decibels + 50) / 50))
    }
}
