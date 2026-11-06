import CoreSpotlight
import CryptoKit
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// What one record puts in the system's search.
nonisolated struct SpotlightRecord: Equatable {
    enum Kind: String { case note, noteEntry, task, bill, expiry }

    var kind: Kind
    /// The model's encoded identifier, as notifications use it.
    var reference: String
    var title: String
    /// The line under the title in the results.
    var details: String
    /// Searched but not shown.
    var text = ""

    var id: String { "\(kind.rawValue)|\(reference)" }

    /// Changes when what's indexed does.
    var fingerprint: String {
        SHA256.hash(data: Data([title, details, text].joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var searchableItem: CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = title
        attributes.contentDescription = details
        attributes.textContent = text
        let item = CSSearchableItem(uniqueIdentifier: id, domainIdentifier: kind.rawValue, attributeSet: attributes)
        // Items otherwise drop out after 30 days, and only changed records are indexed again.
        item.expirationDate = .distantFuture
        return item
    }
}

/// Notes, open to-dos, bills and expiry dates in the system's search: swipe down on the Home Screen
/// and they're there. The index stays on this device. With the app lock on nothing goes in, because
/// search would show what the lock is hiding.
final class SpotlightIndex {
    static let shared = SpotlightIndex()

    /// iOS search only matches titles, whatever else an item has in it. So each entry of a note is an
    /// item too, its words as the title, which is how a note can be found by what it says.
    private static let maxEntryTitle = 300
    /// In caches on purpose: a phone restored from a backup comes back with no index, and this
    /// mustn't come back saying everything is in it.
    private static let stateURL = URL.cachesDirectory.appending(path: "spotlight-index.json")

    /// Unit tests and throwaway stores stay out of the person's search.
    private static var isThrowaway: Bool {
        SyncSettings.isTesting || ProcessInfo.processInfo.arguments.contains("-inMemoryStore")
    }

    private var pending: Task<Void, Never>?

    /// Coalesces bursts of saves into one update.
    func setNeedsRefresh() {
        guard !Self.isThrowaway else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await refresh(context: AppSchema.shared.mainContext)
        }
    }

    private func refresh(context: ModelContext) async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let index = CSSearchableIndex.default()
        if AppLock.isEnabled {
            guard FileManager.default.fileExists(atPath: Self.stateURL.path()) else { return }
            try? await index.deleteAllSearchableItems()
            try? FileManager.default.removeItem(at: Self.stateURL)
            return
        }
        // New records have no lasting identifier until they're saved.
        if context.hasChanges { try? context.save() }
        let records = Self.records(in: context)
        let indexed = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: Self.stateURL))) ?? [:]
        let changes = Self.changes(from: indexed, to: records)
        guard !changes.changed.isEmpty || !changes.removed.isEmpty else { return }
        do {
            if !changes.removed.isEmpty { try await index.deleteSearchableItems(withIdentifiers: changes.removed) }
            if !changes.changed.isEmpty { try await index.indexSearchableItems(changes.changed.map(\.searchableItem)) }
            let state = Dictionary(records.map { ($0.id, $0.fingerprint) }, uniquingKeysWith: { first, _ in first })
            try JSONEncoder().encode(state).write(to: Self.stateURL, options: .atomic)
        } catch {
            // Tried again next time: nothing was recorded as done.
        }
    }

    static func changes(from indexed: [String: String], to records: [SpotlightRecord]) -> (changed: [SpotlightRecord], removed: [String]) {
        let ids = Set(records.map(\.id))
        return (records.filter { indexed[$0.id] != $0.fingerprint }, indexed.keys.filter { !ids.contains($0) })
    }

    static func records(in context: ModelContext) -> [SpotlightRecord] {
        let notes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        let tasks = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.isCompleted }))) ?? []
        let bills = (try? context.fetch(FetchDescriptor<Bill>(predicate: #Predicate { $0.isActive }))) ?? []
        let expiries = (try? context.fetch(FetchDescriptor<ExpiryItem>(predicate: #Predicate { !$0.isArchived }))) ?? []
        func reference(_ model: some PersistentModel) -> String { ModelRef.encode(model.persistentModelID) }
        func line(_ parts: String...) -> String { parts.filter { !$0.isEmpty }.joined(separator: " · ") }

        return notes.flatMap { note in
            let entries = note.sortedEntries
            let name = note.displayTitle
            return [SpotlightRecord(kind: .note, reference: reference(note), title: name, details: String((entries.last?.text ?? "").prefix(120)))]
                + entries.map { entry in
                    SpotlightRecord(kind: .noteEntry, reference: reference(entry),
                                    title: String(entry.text.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(maxEntryTitle)),
                                    details: line(name, entry.date.formatted(date: .abbreviated, time: .omitted)))
                }
        } + tasks.map { task in
            let due = task.dueDate.map { $0.formatted(date: .abbreviated, time: task.hasDueTime ? .shortened : .omitted) } ?? ""
            return SpotlightRecord(kind: .task, reference: reference(task), title: task.title, details: line(due, task.listName),
                                   text: ([task.notes] + (task.subtasks ?? []).map(\.title)).joined(separator: "\n"))
        } + bills.map { bill in
            SpotlightRecord(kind: .bill, reference: reference(bill), title: bill.name,
                            details: line(bill.nextDueDate.formatted(date: .abbreviated, time: .omitted), bill.amount.money(bill.currencyCode)),
                            text: bill.note)
        } + expiries.map { item in
            SpotlightRecord(kind: .expiry, reference: reference(item), title: item.name, details: item.expiryText, text: item.note)
        }
    }

    /// A result tapped: shows the record the way a tapped reminder does.
    static func open(_ id: String, router: AppRouter, context: ModelContext) {
        guard let bar = id.firstIndex(of: "|"), let kind = SpotlightRecord.Kind(rawValue: String(id[..<bar])) else { return }
        let reference = String(id[id.index(after: bar)...])
        switch kind {
        case .note:
            if let note = ModelRef.fetch(Note.self, reference, in: context) { router.open(note) }
        case .noteEntry:
            if let note = ModelRef.fetch(NoteEntry.self, reference, in: context)?.note { router.open(note) }
        case .task: router.open(.task, id: reference)
        case .bill: router.open(.bill, id: reference)
        case .expiry: router.open(.expiry, id: reference)
        }
    }
}
