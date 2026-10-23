import Foundation
import SwiftData

/// A notebook for one ongoing matter or a piece of reference: a title plus entries in time order.
@Model
final class Note {
    var title: String = ""
    var isPinned: Bool = false
    var createdAt: Date = Date.now
    /// Bumped whenever an entry is added or edited; drives the list order.
    var updatedAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \NoteEntry.note)
    var entries: [NoteEntry]? = []

    init(title: String) {
        self.title = title
        self.createdAt = .now
        self.updatedAt = .now
    }

    var sortedEntries: [NoteEntry] {
        (entries ?? []).sorted { ($0.date, $0.createdAt) < ($1.date, $1.createdAt) }
    }

    var latestEntry: NoteEntry? {
        (entries ?? []).max { ($0.date, $0.createdAt) < ($1.date, $1.createdAt) }
    }

    var displayTitle: String {
        title.trimmed.isEmpty ? String(localized: "未命名笔记") : title
    }

    /// Entries marked as key points or with highlighted passages.
    var importantCount: Int {
        (entries ?? []).filter(\.isImportant).count
    }

    /// Reminders set on sentences in this note that are still open.
    var openReminderCount: Int {
        openReminders.count
    }

    var openReminders: [TaskItem] {
        (entries ?? []).flatMap { $0.linkedTasks ?? [] }.filter { !$0.isCompleted }
    }

    /// Open reminders as "铺砖 2026-10-21", so tidying a new entry doesn't suggest them again.
    var openReminderKeys: Set<String> {
        Set(openReminders.compactMap { task in
            task.dueDate.map { NoteOrganizer.reminderKey(title: task.title, date: NoteOrganizer.dayString($0)) }
        })
    }

    /// Adds an entry and moves the note to the top of the list.
    @discardableResult
    func append(_ text: String, date: Date = .now, source: EntrySource = .manual, in context: ModelContext) -> NoteEntry {
        let entry = NoteEntry(text: text, date: date, source: source)
        context.insert(entry)
        entry.note = self
        updatedAt = .now
        return entry
    }

    /// Everything searchable: title, entry text, file names, and text read from images and PDFs.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmed.lowercased()
        guard !needle.isEmpty else { return true }
        if title.lowercased().contains(needle) { return true }
        return (entries ?? []).contains { $0.matches(needle) }
    }
}

@Model
final class NoteEntry {
    var text: String = ""
    /// When this happened; editable, defaults to when it was written.
    var date: Date = Date.now
    var createdAt: Date = Date.now
    var editedAt: Date?
    var sourceRaw: String = EntrySource.manual.rawValue
    /// A key point: the whole entry stands out in the timeline.
    var isKeyPoint: Bool = false
    /// Sentences (or any selected text) marked like with a highlighter pen; JSON [String].
    var highlightsData: Data?

    var note: Note?
    @Relationship(deleteRule: .cascade, inverse: \Attachment.noteEntry)
    var attachments: [Attachment]? = []
    /// To-dos created from sentences in this entry.
    @Relationship(deleteRule: .nullify, inverse: \TaskItem.sourceEntry)
    var linkedTasks: [TaskItem]? = []

    init(text: String, date: Date = .now, source: EntrySource = .manual) {
        self.text = text
        self.date = date
        self.createdAt = .now
        self.sourceRaw = source.rawValue
    }

    var source: EntrySource { EntrySource(rawValue: sourceRaw) ?? .manual }

    /// Highlighted passages, in the order they were marked. Ones no longer in the text are dropped.
    var highlights: [String] {
        get { (JSONStore.decode([String].self, from: highlightsData) ?? []).filter { text.contains($0) } }
        set {
            var seen = Set<String>()
            let kept = newValue.map(\.trimmed).filter { !$0.isEmpty && seen.insert($0).inserted }
            highlightsData = kept.isEmpty ? nil : JSONStore.encode(kept)
        }
    }

    func isHighlighted(_ passage: String) -> Bool {
        highlights.contains(passage.trimmed)
    }

    func toggleHighlight(_ passage: String) {
        let passage = passage.trimmed
        highlights = isHighlighted(passage) ? highlights.filter { $0 != passage } : highlights + [passage]
    }

    /// Worth showing under "只看重点": marked as a key point, or holding a highlight.
    var isImportant: Bool { isKeyPoint || !highlights.isEmpty }

    /// `needle` must already be lowercased.
    func matches(_ needle: String) -> Bool {
        if text.lowercased().contains(needle) { return true }
        return (attachments ?? []).contains {
            $0.fileName.lowercased().contains(needle) || $0.recognizedText.lowercased().contains(needle)
        }
    }

    /// Sentences, for picking one to set a reminder on.
    var sentences: [String] { Sentences.split(text) }
}

nonisolated enum Sentences {
    /// Splits on Chinese and Western sentence ends and line breaks, keeping the punctuation.
    static func split(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if "。！？!?；;\n".contains(character) {
                let sentence = current.trimmed
                if !sentence.isEmpty { result.append(sentence) }
                current = ""
            }
        }
        if !current.trimmed.isEmpty { result.append(current.trimmed) }
        return result
    }
}
