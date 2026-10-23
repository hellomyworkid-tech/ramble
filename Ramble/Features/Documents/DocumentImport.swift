import Foundation
import SwiftData

/// Where a reading's summary and files end up.
enum DocumentDestination {
    /// From a note's composer: a new entry in that note, holding the files.
    case newEntry(Note)
    /// Files already saved in an entry: the summary is added to that entry.
    case entry(NoteEntry)
    /// From "记一下": the AI picks (or names) the note.
    case anywhere

    /// What the model is told: nil lets it choose a note, "" is a note without a name yet.
    var noteTitle: String? {
        switch self {
        case .newEntry(let note): note.title.trimmed
        case .entry(let entry): entry.note?.title.trimmed ?? ""
        case .anywhere: nil
        }
    }
}

/// A reading to present: the files and where the result goes.
struct DocumentReading: Identifiable {
    let id = UUID()
    let files: [DraftAttachment]
    let destination: DocumentDestination
    /// What the person wrote next to the files, for the AI to follow.
    var request = ""
}

enum DocumentImport {
    /// Points the summary at the destination's note or entry.
    static func prepare(_ drafts: inout [CaptureDraft], for destination: DocumentDestination) {
        guard let index = drafts.firstIndex(where: { $0.kind == .note }) else { return }
        switch destination {
        case .newEntry(let note):
            drafts[index].existingNote = note
            drafts[index].updatesExisting = true
            if !note.title.trimmed.isEmpty { drafts[index].title = note.title }
        case .entry(let entry):
            drafts[index].appendsToEntry = entry
            drafts[index].existingNote = nil
            drafts[index].title = entry.note?.title ?? drafts[index].title
        case .anywhere:
            break
        }
    }

    /// Whether something in `drafts` can hold the files (a note, an expiry item or a ledger entry).
    static func keepsFiles(_ drafts: [CaptureDraft], destination: DocumentDestination) -> Bool {
        guard case .anywhere = destination else { return true }
        return drafts.contains { [.note, .expiry, .expense, .income, .transfer].contains($0.kind) }
    }

    /// Saves the drafts, then the new files with the summary, or with the first record
    /// that keeps files when the person dropped the summary.
    @discardableResult
    static func save(_ drafts: [CaptureDraft], files: [DraftAttachment], destination: DocumentDestination,
                     in context: ModelContext, baseCurrency: String, now: Date = .now) -> [SavedRecord] {
        // Notes first, so reminders can link to the line they came from.
        var records = drafts.filter { $0.kind == .note }.compactMap { $0.save(in: context, baseCurrency: baseCurrency, now: now) }
        let entries = records.compactMap(\.noteEntry)
        for draft in drafts where draft.kind != .note {
            if let record = draft.save(in: context, baseCurrency: baseCurrency, linking: entries, now: now) {
                records.append(record)
            }
        }

        // A note that had no name takes the one the AI suggested.
        if case .newEntry(let note) = destination, note.title.trimmed.isEmpty,
           let suggested = drafts.first(where: { $0.kind == .note })?.title.trimmed, !suggested.isEmpty {
            note.title = suggested
        }

        var holder = records.first(where: \.keepsFiles)
        if holder == nil, case .newEntry(let note) = destination, files.contains(where: { $0.model == nil }) {
            holder = .noteEntry(note.append("", date: now, in: context))
        }
        // Files already saved stay where they are; they only pick up the recognized text.
        let keep = holder != nil ? files : files.filter { $0.model != nil }
        DraftAttachment.sync(keep, replacing: nil, in: context) { attachment in
            _ = holder?.attach(attachment)
        }
        return records
    }
}
