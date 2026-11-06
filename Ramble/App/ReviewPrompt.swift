import Foundation

/// When to ask for a rating: after a few captures have gone through, at most once per version.
/// iOS decides whether the request shows anything, and shows it no more than three times a year.
enum ReviewPrompt {
    static let capturesNeeded = 5
    static let countKey = "review.savedCaptures"
    static let versionKey = "review.askedVersion"

    /// A saved capture earned the question; the capture sheet closing asks it.
    static var isDue = false

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// Counts a saved capture and says whether it's time to ask.
    static func captureSaved(version: String = currentVersion, defaults: UserDefaults = .standard) -> Bool {
        let count = defaults.integer(forKey: countKey) + 1
        guard count >= capturesNeeded, defaults.string(forKey: versionKey) != version else {
            defaults.set(count, forKey: countKey)
            return false
        }
        defaults.set(0, forKey: countKey)
        defaults.set(version, forKey: versionKey)
        return true
    }
}
