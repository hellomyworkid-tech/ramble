import Foundation

/// Lets the downloaded models go a minute after their last use. The open language model holds
/// about 2.3 GB and the speech model about 1 GB; kept until the app went to the background, they
/// left an 8 GB iPhone short of memory for as long as the app stayed open: the system squeezed
/// and killed other apps, and everything stuttered. Each reloads in a second or two when needed.
@MainActor
enum ModelIdleRelease {
    static let delay: Duration = .seconds(60)

    private static var languageModelUses = 0
    private static var languageModelRelease: Task<Void, Never>?
    private static var speechModelRelease: Task<Void, Never>?

    /// A request to the on-device language model starts.
    static func languageModelInUse() {
        languageModelUses += 1
        languageModelRelease?.cancel()
        languageModelRelease = nil
    }

    /// A request finished (or the model was loaded ahead): the countdown starts once nothing uses it.
    static func languageModelIdle(endingUse: Bool = true) {
        if endingUse { languageModelUses = max(0, languageModelUses - 1) }
        guard languageModelUses == 0 else { return }
        languageModelRelease?.cancel()
        languageModelRelease = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, languageModelUses == 0 else { return }
            await LocalAI.releaseMemory()
        }
    }

    /// A recording with the speech model ended.
    static func speechModelIdle() {
        speechModelRelease?.cancel()
        speechModelRelease = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, SpeechRecorder.modelRecordings == 0 else { return }
            await SpeechModelEngine.shared.unload()
        }
    }
}
