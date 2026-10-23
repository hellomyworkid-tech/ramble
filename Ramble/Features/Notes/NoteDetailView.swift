import SwiftData
import SwiftUI

/// One note: its entries in time order, and a composer at the bottom for adding more
/// by typing, dictating (with AI tidying) or attaching photos and files.
struct NoteDetailView: View {
    @Bindable var note: Note
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router

    @State private var composerText = ""
    @State private var pending: [DraftAttachment] = []
    @State private var picker = AttachmentPickerState()
    @State private var recorder = SpeechRecorder()
    @State private var textBeforeRecording = ""
    @State private var isOrganizing = false
    @State private var composerMessage: String?
    @State private var review: NoteReview?
    @State private var consentProvider: AIProvider?
    @State private var editingEntry: NoteEntry?
    @State private var pickingSentence: NoteEntry?
    @State private var editingTask: TaskItem?
    @State private var preview: PreviewFile?
    @State private var photoMessage: String?
    @State private var confirmDeleteEntry: NoteEntry?
    @State private var documentReading: DocumentReading?
    @State private var highlightingEntry: NoteEntry?
    @State private var showsImportantOnly = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    TextField("笔记名称", text: $note.title, axis: .vertical)
                        .font(.title2.weight(.bold))
                        .onSubmit { note.updatedAt = .now }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))

                if note.sortedEntries.isEmpty {
                    Section {
                        Text("在下面写第一条记录，或者点麦克风直接说。以后每次有新进展就追加一条，日期会自动记下。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else if showsImportantOnly, days.isEmpty {
                    Section {
                        Text("还没有重点。长按一条记录，选「标为重点」或「高亮某句话」。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(days, id: \.self) { day in
                    Section {
                        ForEach(entriesByDay[day] ?? []) { entry in
                            NoteEntryCell(entry: entry,
                                          onOpenTask: { editingTask = $0 },
                                          onPreview: { attachment, all in preview = PreviewFile(attachment: attachment, among: all) },
                                          onSavePhoto: { attachment in
                                              let data = attachment.data
                                              Task { photoMessage = await PhotoSaver.saveAndDescribe(data) }
                                          })
                                .equatable()
                                .id(entry.persistentModelID)
                                .listRowBackground(entry.isKeyPoint ? ModuleColor.keyPointTint : nil)
                                .contextMenu { menu(for: entry) }
                                .swipeActions {
                                    Button("删除", systemImage: "trash", role: .destructive) { confirmDeleteEntry = entry }
                                    Button("编辑", systemImage: "pencil") { editingEntry = entry }
                                        .tint(.gray)
                                }
                                .swipeActions(edge: .leading) {
                                    Button(entry.isKeyPoint ? "取消重点" : "重点", systemImage: entry.isKeyPoint ? "star.slash" : "star") {
                                        toggleKeyPoint(entry)
                                    }
                                    .tint(ModuleColor.keyPoint)
                                    Button("设提醒", systemImage: "bell") { pickingSentence = entry }
                                        .tint(ModuleColor.notes)
                                }
                        }
                    } header: {
                        Text(DayText.dayWithWeekday(day) + (Calendar.current.isDate(day, equalTo: .now, toGranularity: .year) ? "" : " · \(day.formatted(.dateTime.year()))"))
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .onChange(of: note.entries?.count) {
                if let last = note.sortedEntries.last {
                    withAnimation { proxy.scrollTo(last.persistentModelID, anchor: .bottom) }
                }
            }
            .onAppear {
                if let last = note.sortedEntries.last { proxy.scrollTo(last.persistentModelID, anchor: .bottom) }
                if note.sortedEntries.isEmpty { composerFocused = note.title.isEmpty == false }
            }
        }
        .navigationTitle(note.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        // The composer takes the bottom edge, like a conversation; the tab bar and its capture bar step aside.
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(showsImportantOnly ? "显示全部记录" : "只看重点", systemImage: showsImportantOnly ? "star.fill" : "star") {
                    withAnimation { showsImportantOnly.toggle() }
                }
                .tint(showsImportantOnly ? ModuleColor.keyPoint : nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(note.isPinned ? "取消置顶" : "置顶", systemImage: note.isPinned ? "pin.fill" : "pin") {
                    note.isPinned.toggle()
                }
            }
        }
        .attachmentPickers(state: $picker) { pending.append($0) }
        .attachmentPreview($preview)
        .transientMessage($photoMessage)
        .sheet(item: $review) { item in
            NavigationStack {
                NoteReviewSheet(review: item, reorganize: { attempt in
                    try await NoteOrganizer.organize(item.original, noteTitle: note.title,
                                                     existingReminders: note.openReminderKeys, attempt: attempt)
                }) { text, reminders, isKeyPoint in
                    if note.title.trimmed.isEmpty, !item.organized.title.trimmed.isEmpty {
                        note.title = item.organized.title.trimmed
                    }
                    addEntry(text: text, source: .ai, reminders: reminders, isKeyPoint: isKeyPoint)
                }
            }
        }
        .sheet(item: $editingEntry) { entry in
            NavigationStack { NoteEntryEditor(entry: entry) }
        }
        .sheet(item: $highlightingEntry) { entry in
            NavigationStack { HighlightPicker(entry: entry) }
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $documentReading) { reading in
            NavigationStack {
                DocumentReaderView(files: reading.files, destination: reading.destination, request: reading.request) {
                    // The files now live in the note; the composer lets go of them, and of the words the AI followed.
                    if case .newEntry = reading.destination {
                        pending = []
                        if !reading.request.isEmpty { composerText = "" }
                    }
                    documentReading = nil
                }
            }
        }
        .sheet(item: $pickingSentence) { entry in
            NavigationStack {
                SentencePicker(entry: entry) { pickingSentence = nil }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $editingTask) { task in
            NavigationStack { TaskEditorView(task: task, showsNoteLink: false) }
        }
        .alert(consentProvider.map { String(localized: "发送给 \($0.displayName) 整理？") } ?? "", isPresented: consentBinding, presenting: consentProvider) { _ in
            Button("同意并继续") {
                AISettings.hasCloudConsent = true
                Task { await organize() }
            }
            Button("取消", role: .cancel) {}
        } message: { provider in
            Text("这段文字会用你自己的 API Key 直接发送到 \(provider.vendor) 处理，不经过我们的服务器。")
        }
        .deletionAlert(String(localized: "删除这条记录？"), item: $confirmDeleteEntry) { entry in
            Button("删除", role: .destructive) {
                context.delete(entry)
                note.updatedAt = .now
            }
        } message: { entry in
            Text("「\(entry.text.count > 40 ? String(entry.text.prefix(40)) + "…" : entry.text)」\n附带的图片和文件会一起删除，由它生成的待办会保留。")
        }
        .onChange(of: recorder.transcript) { _, spoken in
            composerText = Punctuation.joining(textBeforeRecording, spoken)
        }
        // No AI model loads while typing (see CaptureSheet): typed entries are saved as written,
        // and 整理 loads it when tapped.
        .onAppear {
            router.hidesCaptureBar = true
            #if DEBUG
            // `-debugNoteText "…"` pre-fills the composer for simulator testing.
            if composerText.isEmpty, let preset = UserDefaults.standard.string(forKey: "debugNoteText") {
                composerText = preset
            }
            #endif
        }
        .onDisappear {
            router.hidesCaptureBar = false
            Task { await recorder.cancel() }
            // A note opened by "+" and left empty isn't worth keeping.
            if note.title.trimmed.isEmpty, (note.entries ?? []).isEmpty, composerText.trimmed.isEmpty {
                context.delete(note)
            }
        }
    }

    // MARK: - Entries

    private var entriesByDay: [Date: [NoteEntry]] {
        let shown = showsImportantOnly ? note.sortedEntries.filter(\.isImportant) : note.sortedEntries
        return Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.date) }
    }

    private func toggleKeyPoint(_ entry: NoteEntry) {
        withAnimation { entry.isKeyPoint.toggle() }
        try? context.save()
    }

    private var days: [Date] { entriesByDay.keys.sorted() }

    @ViewBuilder
    private func menu(for entry: NoteEntry) -> some View {
        Button(entry.isKeyPoint ? "取消重点" : "标为重点", systemImage: entry.isKeyPoint ? "star.slash" : "star") {
            toggleKeyPoint(entry)
        }
        Button("高亮某句话", systemImage: "highlighter") { highlightingEntry = entry }
        Button("给某句话设提醒", systemImage: "bell") { pickingSentence = entry }
        let readable = DraftAttachment.drafts(from: entry.attachments)
            .filter { DocumentText.isReadable(kind: $0.kind, contentType: $0.contentType, fileName: $0.fileName) }
        if !readable.isEmpty {
            Button("AI 读附件", systemImage: "sparkles") {
                documentReading = DocumentReading(files: readable, destination: .entry(entry))
            }
        }
        Button("编辑", systemImage: "pencil") { editingEntry = entry }
        Button("拷贝", systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.text }
        Button("删除", systemImage: "trash", role: .destructive) { confirmDeleteEntry = entry }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !pending.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if pending.contains(where: { DocumentText.isReadable(kind: $0.kind, contentType: $0.contentType, fileName: $0.fileName) }) {
                            Button {
                                documentReading = DocumentReading(files: pending, destination: .newEntry(note),
                                                                  request: composerText.trimmed)
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: "sparkles")
                                        .font(.title3)
                                    Text("AI 读一下")
                                        .font(.caption.weight(.semibold))
                                }
                                .foregroundStyle(.white)
                                .frame(width: 64, height: 56)
                                .background(ModuleColor.notes, in: .rect(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .disabled(isOrganizing || recorder.state != .idle)
                        }
                        ForEach(pending) { item in
                            AttachmentTile(kind: item.kind, thumbnail: item.thumbnail, fileName: item.fileName, size: 56)
                                .overlay(alignment: .topTrailing) {
                                    Button("移除", systemImage: "xmark.circle.fill") {
                                        pending.removeAll { $0.id == item.id }
                                    }
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                                    .offset(x: 6, y: -6)
                                }
                        }
                    }
                    .padding(.top, 6)
                    .padding(.horizontal, 2)
                }
            }
            if isOrganizing {
                Label("正在整理…", systemImage: "sparkles")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if recorder.state == .recording {
                Label("正在听，说完再点一下麦克风", systemImage: "waveform")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let message = composerMessage ?? recorder.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(ModuleColor.warning)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button("照片", systemImage: "photo.on.rectangle") { picker.showsPhotos = true }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button("拍照", systemImage: "camera") { picker.showsCamera = true }
                    }
                    Button("文件", systemImage: "doc") { picker.showsFiles = true }
                } label: {
                    Image(systemName: "paperclip")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(Text("添加图片或文件"))

                HStack(alignment: .top, spacing: 4) {
                    if recorder.state == .recording || recorder.state == .finishing {
                        LiveTranscript(text: composerText, placeholder: "正在听…", maxLines: 6)
                    } else {
                        TextField("写一条记录，或者点麦克风说", text: $composerText, axis: .vertical)
                            .lineLimit(1...6)
                            .focused($composerFocused)
                    }
                    if !composerText.isEmpty, recorder.state == .idle {
                        Button("清空", systemImage: "xmark.circle.fill") {
                            composerText = ""
                            textBeforeRecording = ""
                            composerMessage = nil
                        }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.tertiary)
                        .buttonStyle(.borderless)
                        .accessibilityLabel("清空内容")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18))

                if !composerText.trimmed.isEmpty, recorder.state == .idle {
                    Button("整理", systemImage: "sparkles") { Task { await organize() } }
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .frame(width: 36, height: 36)
                        .disabled(isOrganizing)
                }
                if canSend, recorder.state == .idle {
                    Button("保存", systemImage: "arrow.up.circle.fill") {
                        // Sent as is, but 「标记一下重点」 still marks it rather than staying in the text.
                        let commands = NoteCommands.extract(composerText)
                        addEntry(text: commands.text.trimmed.isEmpty ? composerText : commands.text, source: .manual,
                                 reminders: [], isKeyPoint: commands.markAsKeyPoint)
                    }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 30))
                    .disabled(isOrganizing)
                } else {
                    MicButton(isRecording: recorder.state == .recording,
                              isBusy: recorder.state == .preparing || recorder.state == .finishing,
                              level: recorder.level, size: 36, action: toggleMic)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var canSend: Bool {
        !composerText.trimmed.isEmpty || !pending.isEmpty
    }

    private func toggleMic() {
        Task {
            if recorder.state == .recording {
                await recorder.stop()
                // Speech reads best after tidying; do it straight away when AI is set up.
                if !composerText.trimmed.isEmpty { await organize() }
                return
            }
            guard recorder.state == .idle else { return }
            composerMessage = nil
            textBeforeRecording = composerText
            composerFocused = false
            LocalAI.prepareWhileListening()
            await recorder.start()
        }
    }

    private func organize() async {
        let text = composerText.trimmed
        guard !text.isEmpty else { return }
        isOrganizing = true
        composerMessage = nil
        defer { isOrganizing = false }
        do {
            let (organized, source) = try await NoteOrganizer.organize(text, noteTitle: note.title, existingReminders: note.openReminderKeys)
            review = NoteReview(original: text, organized: organized, source: source)
        } catch AIError.needsConsent(let provider) {
            consentProvider = provider
        } catch {
            composerMessage = String(localized: "\(error.localizedDescription) 可以直接点 ↑ 按原话保存。")
        }
    }

    private func addEntry(text: String, source: EntrySource, reminders: [ReminderDraft], isKeyPoint: Bool = false) {
        let body = text.trimmed
        guard !body.isEmpty || !pending.isEmpty else { return }
        let entry = note.append(body, source: source, in: context)
        entry.isKeyPoint = isKeyPoint
        DraftAttachment.sync(pending, replacing: nil, in: context) { $0.noteEntry = entry }
        for reminder in reminders where reminder.include && !reminder.title.trimmed.isEmpty {
            let task = TaskItem(title: reminder.title.trimmed,
                                dueDate: reminder.hasTime ? reminder.date : Calendar.current.startOfDay(for: reminder.date),
                                hasDueTime: reminder.hasTime)
            context.insert(task)
            task.sourceEntry = entry
            task.sourceQuote = reminder.quote
        }
        composerText = ""
        pending = []
        composerMessage = nil
        try? context.save()
        NoteIndexer.indexAttachments(of: entry)
    }

    private var consentBinding: Binding<Bool> {
        Binding(get: { consentProvider != nil }, set: { if !$0 { consentProvider = nil } })
    }
}

/// Reads text out of newly attached images and files so search can find them.
enum NoteIndexer {
    static func indexAttachments(of entry: NoteEntry) {
        let pending = (entry.attachments ?? []).filter { $0.recognizedText.isEmpty }
        guard !pending.isEmpty else { return }
        Task {
            for attachment in pending {
                guard let data = attachment.data else { continue }
                attachment.recognizedText = await AttachmentImporter.extractText(from: data, kind: attachment.kind,
                                                                                  contentType: attachment.contentTypeID,
                                                                                  fileName: attachment.fileName)
            }
        }
    }
}

/// One entry: time, text with its reminder sentences underlined, attachments, and the reminders.
/// Equal while it shows the same entry: typing in the composer redraws the page, and without this
/// every entry (its highlights, its reminders) was rebuilt on each keystroke. Changes to the entry
/// itself still redraw it, through observation.
struct NoteEntryCell: View, Equatable {
    let entry: NoteEntry
    let onOpenTask: (TaskItem) -> Void
    /// The attachment tapped, and all of the entry's (to swipe through its photos).
    let onPreview: (Attachment, [Attachment]) -> Void
    let onSavePhoto: (Attachment) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.entry === rhs.entry }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if entry.isKeyPoint {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                        Text("重点")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ModuleColor.keyPoint)
                }
                Text(entry.date.formatted(date: .omitted, time: .shortened))
                if entry.source == .ai {
                    Image(systemName: "sparkles")
                        .accessibilityLabel(Text("AI 整理"))
                }
                if entry.editedAt != nil {
                    Text("已编辑")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !entry.text.isEmpty {
                Text(highlightedText)
                    .textSelection(.enabled)
            }

            let attachments = (entry.attachments ?? []).sorted { $0.createdAt < $1.createdAt }
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            Button {
                                onPreview(attachment, attachments)
                            } label: {
                                AttachmentTile(kind: attachment.kind, thumbnail: attachment.thumbnailData,
                                               fileName: attachment.fileName, size: 72)
                            }
                            .buttonStyle(.borderless)
                            .contextMenu {
                                Button(attachment.kind == .image ? "查看" : "预览", systemImage: "eye") {
                                    onPreview(attachment, attachments)
                                }
                                if attachment.kind == .image {
                                    Button("存储到相册", systemImage: "square.and.arrow.down") { onSavePhoto(attachment) }
                                }
                            }
                        }
                    }
                }
            }

            ForEach(linkedTasks) { task in
                Button {
                    onOpenTask(task)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "bell.fill")
                            .foregroundStyle(task.isCompleted ? Color.secondary : ModuleColor.notes)
                        Text(task.title)
                            .strikethrough(task.isCompleted)
                            .foregroundStyle(task.isCompleted ? .secondary : .primary)
                        if let due = task.dueDate {
                            Text(DayText.due(due, hasTime: task.hasDueTime))
                                .foregroundStyle(task.isOverdue() ? Color.red : Color.secondary)
                        }
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(ModuleColor.notes.opacity(0.10), in: .capsule)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private var linkedTasks: [TaskItem] {
        (entry.linkedTasks ?? []).sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    /// Highlighted passages get a marker background and semibold weight (so they don't rely on
    /// colour alone); sentences with a reminder are underlined in the note colour (gray once done).
    private var highlightedText: AttributedString {
        var text = AttributedString(entry.text)
        for passage in entry.highlights {
            var searchStart = text.startIndex
            while searchStart < text.endIndex, let range = text[searchStart...].range(of: passage) {
                text[range].backgroundColor = ModuleColor.highlighter
                text[range].font = .body.weight(.semibold)
                searchStart = range.upperBound
            }
        }
        for task in entry.linkedTasks ?? [] where !task.sourceQuote.isEmpty {
            guard let range = text.range(of: task.sourceQuote) else { continue }
            text[range].underlineStyle = Text.LineStyle(pattern: .solid, color: task.isCompleted ? .secondary : ModuleColor.notes)
            if !task.isCompleted {
                text[range].foregroundColor = ModuleColor.notes
            }
        }
        return text
    }
}
