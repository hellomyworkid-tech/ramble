import Foundation

/// One question in 问一问 and its answer, as it was when asked.
nonisolated struct AskRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var question: String
    var answer: AskAnswer
    /// Amounts in the answer are in this currency (the base currency at the time).
    var currency: String
    /// How long AI took, when AI read the question.
    var seconds: Double?
}

/// Questions asked in 问一问, kept on this device so they're still there next time (newest last).
/// Not synced and not in backups: answers are worked out from the records, and 「重新问」 does that again.
nonisolated enum AskHistory {
    static let limit = 100

    static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "ask-history.json")
    }

    static func load(from url: URL = defaultURL) -> [AskRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([AskRecord].self, from: data)) ?? []
    }

    /// Keeps the newest `limit`.
    static func save(_ records: [AskRecord], to url: URL = defaultURL) {
        let kept = Array(records.suffix(limit))
        guard let data = try? JSONEncoder().encode(kept) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func append(_ record: AskRecord, to url: URL = defaultURL) {
        save(load(from: url) + [record], to: url)
    }

    static func clear(at url: URL = defaultURL) {
        try? FileManager.default.removeItem(at: url)
    }
}
