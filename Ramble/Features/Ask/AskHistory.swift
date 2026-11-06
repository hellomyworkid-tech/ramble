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

/// A round of questions, like a chat in an AI app: within one, a question can carry on from the last.
nonisolated struct AskConversation: Codable, Identifiable, Equatable {
    var id = UUID()
    var records: [AskRecord] = []

    var title: String { records.first?.question ?? "" }
    var lastDate: Date { records.last?.date ?? .distantPast }
}

/// The conversations in 问一问, kept on this device, newest first.
/// Not synced and not in backups: answers are worked out from the records, and 「重新问」 does that again.
nonisolated enum AskHistory {
    /// Questions kept across all conversations; the oldest go first.
    static let limit = 300
    /// A conversation left for longer is over: opening 问一问 starts a new one.
    static let resumeWindow: TimeInterval = 30 * 60

    static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "ask-conversations.json")
    }

    /// The single list of questions from before conversations.
    static var legacyURL: URL {
        URL.applicationSupportDirectory.appending(path: "ask-history.json")
    }

    static func load(from url: URL = defaultURL, legacy: URL = legacyURL) -> [AskConversation] {
        if let data = try? Data(contentsOf: url) {
            return (try? JSONDecoder().decode([AskConversation].self, from: data)) ?? []
        }
        guard let data = try? Data(contentsOf: legacy),
              let records = try? JSONDecoder().decode([AskRecord].self, from: data) else { return [] }
        let split = conversations(from: records)
        save(split, to: url)
        try? FileManager.default.removeItem(at: legacy)
        return split
    }

    /// Splits a list of questions (oldest first) wherever they were left for longer than `resumeWindow`.
    static func conversations(from records: [AskRecord]) -> [AskConversation] {
        var conversations: [AskConversation] = []
        for record in records {
            if let last = conversations.last, record.date.timeIntervalSince(last.lastDate) < resumeWindow {
                conversations[conversations.count - 1].records.append(record)
            } else {
                conversations.append(AskConversation(records: [record]))
            }
        }
        return conversations.reversed()
    }

    static func save(_ conversations: [AskConversation], to url: URL = defaultURL) {
        var room = limit
        let kept = conversations.compactMap { conversation -> AskConversation? in
            guard room > 0 else { return nil }
            var trimmed = conversation
            trimmed.records = Array(conversation.records.suffix(room))
            room -= trimmed.records.count
            return trimmed
        }
        guard let data = try? JSONEncoder().encode(kept) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Adds a question to a conversation, which starts with its first one and moves to the top with each new one.
    static func add(_ record: AskRecord, to id: UUID, at url: URL = defaultURL) {
        var conversations = load(from: url)
        var conversation = conversations.first { $0.id == id } ?? AskConversation(id: id)
        conversations.removeAll { $0.id == id }
        conversation.records.append(record)
        conversations.insert(conversation, at: 0)
        save(conversations, to: url)
    }

    /// After a question is deleted; a conversation with none left is gone.
    static func update(_ id: UUID, records: [AskRecord], at url: URL = defaultURL) {
        var conversations = load(from: url)
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        if records.isEmpty {
            conversations.remove(at: index)
        } else {
            conversations[index].records = records
        }
        save(conversations, to: url)
    }

    /// The conversation to carry on with when 问一问 opens: one left only a moment ago,
    /// say to look at a record from an answer.
    static func resumable(now: Date = .now, from url: URL = defaultURL) -> AskConversation? {
        load(from: url).first { now.timeIntervalSince($0.lastDate) < resumeWindow }
    }

    static func clear(at url: URL = defaultURL) {
        try? FileManager.default.removeItem(at: url)
    }
}
