import SwiftData
import SwiftUI

struct NotesView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]
    @State private var path: [Note] = []
    /// Notes made with "+" here, so one left empty can be thrown away once it's closed.
    @State private var newNotes: [Note] = []
    @State private var query = ""
    @State private var pendingDelete: Note?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !pinned.isEmpty {
                    Section("已置顶") {
                        ForEach(pinned) { row($0) }
                    }
                }
                Section {
                    ForEach(others) { row($0) }
                } header: {
                    if !pinned.isEmpty { Text("其他") }
                }
            }
            .overlay { emptyState }
            .searchable(text: $query, prompt: Text("搜索笔记、图片和文件里的字"))
            .navigationTitle("笔记")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("新建笔记", systemImage: "square.and.pencil", action: createNote)
                }
            }
            .navigationDestination(for: Note.self) { note in
                NoteDetailView(note: note)
            }
            .deletionAlert(String(localized: "删除这个笔记？"), item: $pendingDelete) { note in
                Button("删除「\(note.displayTitle)」", role: .destructive) {
                    context.delete(note)
                    pendingDelete = nil
                }
            } message: { _ in
                Text("里面的记录、图片和文件都会删除。由它生成的待办会保留。")
            }
            .onChange(of: router.focus, initial: true) { openFocusedNote() }
            .onChange(of: path) { old, new in
                // A new note left with nothing in it isn't worth keeping. Only once it's closed:
                // the page also "disappears" while something full-screen covers it.
                for note in old where !new.contains(note) {
                    guard let index = newNotes.firstIndex(where: { $0 === note }) else { continue }
                    newNotes.remove(at: index)
                    if note.title.trimmed.isEmpty, (note.entries ?? []).isEmpty {
                        context.delete(note)
                    }
                }
            }
        }
    }

    private var filtered: [Note] {
        query.trimmed.isEmpty ? notes : notes.filter { $0.matches(query) }
    }

    private var pinned: [Note] { filtered.filter(\.isPinned) }
    private var others: [Note] { filtered.filter { !$0.isPinned } }

    private func row(_ note: Note) -> some View {
        NavigationLink(value: note) {
            NoteRow(note: note, query: query)
        }

        .swipeActions(edge: .leading) {
            Button(note.isPinned ? "取消置顶" : "置顶", systemImage: note.isPinned ? "pin.slash" : "pin") {
                withAnimation { note.isPinned.toggle() }
            }
            .tint(ModuleColor.notes)
        }
        .swipeActions {
            Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = note }
        }
        .contextMenu {
            Button(note.isPinned ? "取消置顶" : "置顶", systemImage: note.isPinned ? "pin.slash" : "pin") {
                note.isPinned.toggle()
            }
            Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = note }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if notes.isEmpty {
            ContentUnavailableView {
                Label("还没有笔记", systemImage: "note.text")
            } description: {
                Text("长期跟踪的事（装修、看病、孩子成长）和要留着备查的资料，都可以记在这里。也可以直接在下方说出来，AI 会帮你归档。")
            } actions: {
                Button("新建笔记", action: createNote)
                    .buttonStyle(.borderedProminent)
            }
        } else if filtered.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    private func createNote() {
        let note = Note(title: "")
        context.insert(note)
        newNotes.append(note)
        path = [note]
    }

    private func openFocusedNote() {
        switch router.focus {
        case .note(let id):
            router.focus = nil
            guard let note = notes.first(where: { $0.persistentModelID == id }) else { return }
            path = [note]
        case .newNote:
            router.focus = nil
            createNote()
        default:
            break
        }
    }
}

private struct NoteRow: View {
    let note: Note
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(ModuleColor.notes)
                        .accessibilityLabel(Text("已置顶"))
                }
                Text(note.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
            }
            if let preview {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 10) {
                Text(DayText.due(note.updatedAt, hasTime: false))
                Text("\(note.entries?.count ?? 0) 条")
                if note.importantCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                        Text("\(note.importantCount)")
                    }
                    .foregroundStyle(ModuleColor.keyPoint)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("\(note.importantCount) 条重点"))
                }
                if note.openReminderCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "bell")
                        Text("\(note.openReminderCount)")
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("\(note.openReminderCount) 个提醒"))
                }
                if hasAttachments {
                    Image(systemName: "paperclip")
                        .accessibilityLabel(Text("有附件"))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// While searching, the entry that matched; otherwise the latest one.
    private var preview: String? {
        let needle = query.trimmed.lowercased()
        if !needle.isEmpty, let hit = note.sortedEntries.last(where: { $0.matches(needle) }) {
            if hit.text.lowercased().contains(needle) { return Self.excerpt(of: hit.text, around: needle) }
            if let file = (hit.attachments ?? []).first(where: { $0.recognizedText.lowercased().contains(needle) || $0.fileName.lowercased().contains(needle) }) {
                return file.kind == .image ? String(localized: "照片里有「\(query.trimmed)」") : String(localized: "文件：\(file.fileName)")
            }
        }
        guard let latest = note.latestEntry else { return nil }
        let text = latest.text.trimmed
        if !text.isEmpty { return text }
        // A photo or file on its own: say what it is.
        let attachments = latest.attachments ?? []
        if let file = attachments.first(where: { $0.kind == .document }) {
            return attachments.count > 1 ? String(localized: "文件：\(file.fileName) 等 \(attachments.count) 个")
                                         : String(localized: "文件：\(file.fileName)")
        }
        return attachments.isEmpty ? nil : String(localized: "\(attachments.count) 张照片")
    }

    private var hasAttachments: Bool {
        (note.entries ?? []).contains { !($0.attachments ?? []).isEmpty }
    }

    /// A slice of `text` that starts a little before the first match.
    static func excerpt(of text: String, around needle: String) -> String {
        let lowered = text.lowercased()
        guard let range = lowered.range(of: needle) else { return text }
        let distance = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
        let start = text.index(text.startIndex, offsetBy: max(0, distance - 12), limitedBy: text.endIndex) ?? text.startIndex
        return (start > text.startIndex ? "…" : "") + String(text[start...])
    }
}
