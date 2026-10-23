import SwiftData
import SwiftUI

/// "Just say it": speak or type → AI organizes → review, answering one follow-up
/// question when the AI was unsure → save everything at once.
struct CaptureSheet: View {
    enum Phase {
        case input, processing, review
    }

    enum ManualRoute: Hashable, Identifiable {
        case task, entry, receipt, bill, expiry
        var id: Self { self }
    }

    private enum MicTarget {
        case note, answer
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context
    @AppStorage(AppSettings.baseCurrencyKey) private var baseCurrency = AppSettings.defaultBaseCurrency
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(filter: #Predicate<Bill> { $0.isActive }) private var bills: [Bill]
    @Query(filter: #Predicate<ExpiryItem> { !$0.isArchived }) private var expiries: [ExpiryItem]
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]
    @Query(filter: #Predicate<TaskItem> { !$0.isCompleted }) private var openTasks: [TaskItem]

    @State private var recorder = SpeechRecorder()
    @State private var micTarget: MicTarget = .note
    @State private var textBeforeRecording = ""

    @State private var phase: Phase = .input
    @State private var text = ""
    @State private var parsedInput = ""
    @State private var drafts: [CaptureDraft] = []
    @State private var fillers: [String] = []
    @State private var followUp = ""
    @State private var answer = ""
    @State private var source: CaptureSource?
    @State private var elapsed: Duration?
    @State private var thinking: AIThinking?
    @State private var errorMessage: String?
    @State private var routeDescription = ""
    @State private var consentProvider: AIProvider?
    @State private var manualRoute: ManualRoute?
    /// Photos and files for the AI to read; what's typed or said with them tells it what to do.
    @State private var files: [DraftAttachment] = []
    @State private var picker = AttachmentPickerState()
    @State private var preview: PreviewFile?
    @State private var readsFiles = false
    @State private var editingDraft: CaptureDraft.ID?
    @State private var showsAISettings = false
    /// Which go at organizing the current input this is; 重新整理 counts up.
    @State private var attempt: AIAttempt = .first
    /// Note drafts whose text is being rewritten into clear sentences after the review shows.
    @State private var tidying: Set<CaptureDraft.ID> = []
    @FocusState private var textFocused: Bool
    /// Text to tidy, or listening to start, when Siri or a widget opened the sheet.
    private let start: CaptureStart?
    @State private var startHandled = false

    init(start: CaptureStart? = nil) {
        self.start = start
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .input: inputForm
                case .processing: processingView
                case .review: reviewForm
                }
            }
            .navigationTitle(phase == .review ? "整理结果" : "记一下")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .navigationDestination(item: $manualRoute) { route in
                switch route {
                case .task: TaskEditorView(task: nil) { dismiss() }
                case .entry: EntryEditorView(entry: nil) { dismiss() }
                case .receipt: EntryEditorView(entry: nil, startsWithReceipt: true) { dismiss() }
                case .bill: BillEditorView(bill: nil) { dismiss() }
                case .expiry: ExpiryEditorView(item: nil) { dismiss() }
                }
            }
            .navigationDestination(isPresented: $readsFiles) {
                DocumentReaderView(files: files, destination: .anywhere, request: text, showsCancel: false) { dismiss() }
            }
            .attachmentPickers(state: $picker) { files.append($0) }
            .attachmentPreview($preview)
            .navigationDestination(item: $editingDraft) { id in
                if let index = drafts.firstIndex(where: { $0.id == id }) {
                    DraftEditorView(draft: $drafts[index], categories: categories, accounts: accounts, notes: notes)
                }
            }
            .navigationDestination(isPresented: $showsAISettings) {
                AISettingsView()
            }
            .alert(consentTitle, isPresented: consentBinding, presenting: consentProvider) { _ in
                Button("同意并继续") {
                    AISettings.hasCloudConsent = true
                    Task { await organize(parsedInput, attempt: attempt) }
                }
                Button("取消", role: .cancel) {}
            } message: { provider in
                Text("这段文字会用你自己的 API Key 直接发送到 \(provider.vendor) 处理，不经过我们的服务器。以后可以在「AI 设置」里关闭。")
            }
        }
        .interactiveDismissDisabled(phase == .review)
        .onChange(of: recorder.transcript) { _, spoken in applySpoken(spoken) }
        // The AI model loads when 整理 is tapped, never while typing: making room for a couple of GB
        // squeezes the other apps' memory, and the keyboard stuttered (as the sheet opened, and later
        // on any pause mid-sentence, when this loaded after 1.5 s without a keystroke).
        .onChange(of: showsAISettings) { _, showing in
            if !showing { refreshRoute() }
        }
        .onAppear {
            refreshRoute()
            if let start, !startHandled {
                startHandled = true
                switch start {
                case .text(let said):
                    text = said
                    Task { await organize(said) }
                case .voice:
                    toggleMic(.note)
                }
            }
            #if DEBUG
            // `-debugCaptureText "…"` pre-fills the note for simulator testing.
            if text.isEmpty, let preset = UserDefaults.standard.string(forKey: "debugCaptureText") {
                text = preset
            }
            #endif
        }
        .onDisappear {
            Task { await recorder.cancel() }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("关闭", systemImage: "xmark", role: .close) { dismiss() }
        }
        if phase == .review {
            ToolbarItem(placement: .topBarTrailing) {
                Button("重说", systemImage: "arrow.counterclockwise") { phase = .input }
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button("AI 设置", systemImage: "gearshape") { showsAISettings = true }
            }
        }
    }

    // MARK: - Input

    private var inputForm: some View {
        Form {
            Section {
                if isListening(.note) {
                    LiveTranscript(text: text, placeholder: "正在听…", minLines: 5, maxLines: 12)
                } else {
                    TextField(files.isEmpty ? "随便说，比如：中午吃饭花了三十五，信用卡十五号要还，护照明年三月到期"
                                            : "可以写给 AI 的话，比如：这是上个月的电费单，记一笔；只记保修到期日",
                              text: $text, axis: .vertical)
                        .lineLimit(5...12)
                        .focused($textFocused)
                        .padding(.trailing, text.isEmpty ? 0 : 26)
                        .clearButton($text, hidden: recorder.state != .idle) {
                            textBeforeRecording = ""
                            errorMessage = nil
                        }
                }
                if !files.isEmpty { fileStrip }
                HStack(spacing: 12) {
                    MicButton(isRecording: isRecording(.note), isBusy: recorder.state == .preparing || recorder.state == .finishing,
                              level: recorder.level) { toggleMic(.note) }
                    if isRecording(.note) {
                        Text("正在听，说完再点一下")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        attachMenu
                    }
                    Spacer()
                    Button {
                        if files.isEmpty {
                            Task { await organize(text) }
                        } else {
                            Task {
                                if recorder.state == .recording { await recorder.stop() }
                                readsFiles = true
                            }
                        }
                    } label: {
                        // An explicit foreground: inside a Form the glyph otherwise takes
                        // the tint and vanishes into the filled button.
                        HStack(spacing: 6) {
                            Image(systemName: files.isEmpty ? "sparkles" : "doc.text.magnifyingglass")
                            Text(files.isEmpty ? "整理" : "AI 读一下")
                        }
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled((files.isEmpty && text.trimmed.isEmpty) || recorder.state == .preparing || recorder.state == .finishing)
                }
                .padding(.vertical, 4)
            } footer: {
                if files.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(routeDescription)
                        Text("点回形针加照片或文件（体检报告、合同、发票……），AI 读出要点；可以同时写上要它怎么做。")
                    }
                } else {
                    Text("体检报告、合同、保修卡、发票：AI 总结要点记进笔记，并建议复查、到期等提醒。上面写的话会一起交给 AI，比如说明这是什么、要记什么。")
                }
            }

            // 「这个月吃饭花了多少」 is a question, not something to record.
            if files.isEmpty, QuestionParser.looksLikeQuestion(text), recorder.state != .recording {
                Section {
                    Button {
                        // The root view closes this sheet, then opens 问一问.
                        router.ask(text)
                    } label: {
                        Label("这像是在提问，点这里查一查", systemImage: "bubble.left.and.text.bubble.right")
                    }
                }
            }

            if let message = errorMessage ?? recorder.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(ModuleColor.warning)
                    Button("打开 AI 设置") { showsAISettings = true }
                }
            }

            Section("手动添加") {
                shortcut("待办", symbol: "checkmark", color: ModuleColor.tasks, route: .task)
                shortcut("记一笔", symbol: "creditcard", color: ModuleColor.money, route: .entry)
                shortcut("扫小票记一笔", symbol: "text.viewfinder", color: ModuleColor.money, route: .receipt)
                shortcut("账单", symbol: "calendar", color: ModuleColor.bills, route: .bill)
                shortcut("到期提醒", symbol: "person.text.rectangle", color: ModuleColor.expiry, route: .expiry)
                shortcut("笔记", symbol: DraftKind.note.symbol, color: ModuleColor.notes) { router.openNewNote() }
            }
        }
    }

    /// Photos and files go in the same box as the words: the AI reads them and does what the words say.
    private var attachMenu: some View {
        Menu {
            Button("照片", systemImage: "photo.on.rectangle") { picker.showsPhotos = true }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("拍照", systemImage: "camera") { picker.showsCamera = true }
            }
            Button("文件", systemImage: "doc") { picker.showsFiles = true }
        } label: {
            Image(systemName: "paperclip")
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel(Text("添加图片或文件"))
    }

    @ViewBuilder
    private var fileStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(files) { file in
                    Button {
                        preview = PreviewFile(draft: file, among: files)
                    } label: {
                        AttachmentTile(kind: file.kind, thumbnail: file.thumbnail, fileName: file.fileName, size: 64)
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .topTrailing) {
                        Button("移除", systemImage: "xmark.circle.fill") {
                            withAnimation { files.removeAll { $0.id == file.id } }
                        }
                        .labelStyle(.iconOnly)
                        .font(.body)
                        .foregroundStyle(.white, .black.opacity(0.55))
                        .buttonStyle(.borderless)
                        .offset(x: 6, y: -6)
                    }
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
        if let message = picker.errorMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private func shortcut(_ title: LocalizedStringResource, symbol: String, color: Color, route: ManualRoute) -> some View {
        shortcut(title, symbol: symbol, color: color) { manualRoute = route }
    }

    private func shortcut(_ title: LocalizedStringResource, symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconTile(symbol: symbol, color: color, size: 30)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var processingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("正在整理…")
                .font(.headline)
            Text(routeDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Review

    private var reviewForm: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("你说的")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(CaptureDraft.highlighted(parsedInput, fillers: fillers))
                        .font(.callout)
                }
                .padding(.vertical, 2)
                // Said it right but organized badly: another go, a little differently, or by the cloud.
                HStack(spacing: 16) {
                    Button("重新整理", systemImage: "arrow.clockwise") {
                        Task { await organize(parsedInput, attempt: attempt.next()) }
                    }
                    if source == .onDevice, AIAttempt.cloudIsAvailable {
                        Button("用\(AISettings.provider.displayName)整理", systemImage: "cloud") {
                            Task { await organize(parsedInput, attempt: attempt.next(forcingCloud: true)) }
                        }
                    }
                }
                .font(.subheadline)
                .buttonStyle(.borderless)
                if !tidying.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在把笔记理顺成通顺的句子…")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            } footer: {
                HStack {
                    Text(summaryLine)
                    Spacer()
                    if let source { SourceBadge(source: source, elapsed: elapsed, thinking: thinking) }
                }
            }

            if !followUp.isEmpty {
                followUpSection
            }

            ForEach($drafts) { $draft in
                DraftCard(draft: $draft,
                          onEdit: { editingDraft = draft.id },
                          onRemove: { remove(draft.id) })
            }
        }
        .safeAreaInset(edge: .bottom) { saveBar }
    }

    private var followUpSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text(followUp)
            }
            HStack(spacing: 10) {
                if isListening(.answer) {
                    LiveTranscript(text: answer, placeholder: "正在听…", maxLines: 4)
                } else {
                    TextField("直接回答，比如：2180，3 月 12 号", text: $answer, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(.trailing, answer.isEmpty ? 0 : 26)
                        .clearButton($answer, hidden: recorder.state != .idle)
                }
                MicButton(isRecording: isRecording(.answer), isBusy: false, level: recorder.level, size: 36) { toggleMic(.answer) }
                Button("发送") {
                    Task { await organize(parsedInput + "\n补充：" + answer.trimmed) }
                }
                .buttonStyle(.borderless)
                .disabled(answer.trimmed.isEmpty)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(ModuleColor.warning)
            }
            Button("先不回答，按现在的结果保存") { followUp = "" }
                .font(.footnote)
                .buttonStyle(.borderless)
        } header: {
            Text("还有几处不确定")
        }
    }

    private var saveBar: some View {
        VStack(spacing: 6) {
            if let problem = drafts.lazy.compactMap(\.problem).first {
                Text("还有一条\(problem)，点那一条补上")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Button(action: save) {
                Text(drafts.count == 1 ? "保存" : "保存 \(drafts.count) 条")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(drafts.isEmpty || drafts.contains { $0.problem != nil })
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.bar)
    }

    private var summaryLine: String {
        let unsure = drafts.reduce(0) { $0 + $1.uncertainCount }
        return unsure > 0
            ? String(localized: "整理出 \(drafts.count) 条，其中 \(unsure) 处需要确认")
            : String(localized: "整理出 \(drafts.count) 条")
    }

    // MARK: - Actions

    private func isRecording(_ target: MicTarget) -> Bool {
        recorder.state == .recording && micTarget == target
    }

    /// Recording, or finishing the last words: the live transcript shows instead of the field.
    private func isListening(_ target: MicTarget) -> Bool {
        (recorder.state == .recording || recorder.state == .finishing) && micTarget == target
    }

    private func toggleMic(_ target: MicTarget) {
        Task {
            if recorder.state == .recording {
                await recorder.stop()
                return
            }
            guard recorder.state == .idle else { return }
            micTarget = target
            textBeforeRecording = target == .note ? text : answer
            textFocused = false
            // Ready by the time the person stops talking.
            LocalAI.prepareWhileListening()
            await recorder.start()
        }
    }

    private func applySpoken(_ spoken: String) {
        let base = textBeforeRecording
        let joined = Punctuation.joining(base, spoken)
        switch micTarget {
        case .note: text = joined
        case .answer: answer = joined
        }
    }

    private func organize(_ input: String, attempt: AIAttempt = .first) async {
        let note = input.trimmed
        guard !note.isEmpty else { return }
        self.attempt = attempt
        if recorder.state == .recording { await recorder.stop() }
        let returnPhase: Phase = phase == .review ? .review : .input
        errorMessage = nil
        parsedInput = note
        phase = .processing
        do {
            let started = ContinuousClock.now
            // 「给这条标记一下重点」 is for the app: taken out of what AI reads, carried out on the note.
            let commands = NoteCommands.extract(note)
            let outcome = try await CaptureEngine.parse(commands.markAsKeyPoint && !commands.text.trimmed.isEmpty ? commands.text : note,
                                                        context: makeContext(), attempt: attempt)
            elapsed = ContinuousClock.now - started
            thinking = outcome.thinking
            fillers = outcome.capture.fillerPhrases
            followUp = outcome.capture.followUpQuestion.trimmed
            source = outcome.source
            drafts = outcome.capture.items.map { item in
                var draft = CaptureDraft(item: item, categories: categories, accounts: accounts, baseCurrency: baseCurrency)
                draft.linkExisting(bills: bills, expiries: expiries, notes: notes, tasks: openTasks)
                if draft.kind == .note, commands.markAsKeyPoint { draft.isKeyPoint = true }
                return draft
            }
            answer = ""
            phase = .review
            if outcome.source == .onDevice { tidyNotes() }
        } catch AIError.needsConsent(let provider) {
            phase = returnPhase
            consentProvider = provider
        } catch {
            errorMessage = error.localizedDescription
            phase = returnPhase
        }
    }

    /// On-device captures keep a note's words as said; rewrite them into clear sentences while
    /// the person looks the result over. An edit made meanwhile wins; quotes follow the new text.
    private func tidyNotes() {
        guard LocalAI.usesOpenModel else { return }
        for draft in drafts where draft.kind == .note && draft.appendsToEntry == nil && !draft.note.trimmed.isEmpty {
            let id = draft.id, said = draft.note
            tidying.insert(id)
            Task {
                defer { tidying.remove(id) }
                guard let cleaned = try? await NoteOrganizer.tidyWithOpenModel(said), cleaned != said,
                      let index = drafts.firstIndex(where: { $0.id == id }), drafts[index].note == said else { return }
                drafts[index].note = cleaned
                for task in drafts.indices where drafts[task].kind == .task && !drafts[task].quote.isEmpty
                    && !cleaned.contains(drafts[task].quote) {
                    drafts[task].quote = NoteOrganizer.anchor(drafts[task].quote, in: cleaned)
                }
            }
        }
    }

    private func makeContext() -> CaptureContext {
        CaptureContext(
            now: .now,
            timeZone: .current,
            baseCurrency: baseCurrency,
            expenseCategories: categories.filter { $0.kind == .expense }.map(\.name),
            incomeCategories: categories.filter { $0.kind == .income }.map(\.name),
            accounts: accounts.filter { !$0.isArchived }.map { ($0.name, $0.kind.rawValue) },
            existingBills: bills.map(\.name),
            existingExpiries: expiries.map(\.name),
            existingNotes: notes.prefix(40).map(\.title).filter { !$0.trimmed.isEmpty }
        )
    }

    private func remove(_ id: CaptureDraft.ID) {
        withAnimation { drafts.removeAll { $0.id == id } }
    }

    private func save() {
        // Notes first, so reminders from the same capture can link to their sentence.
        let entries = drafts.filter { $0.kind == .note }.compactMap { $0.save(in: context, baseCurrency: baseCurrency)?.noteEntry }
        for draft in drafts where draft.kind != .note {
            draft.save(in: context, baseCurrency: baseCurrency, linking: entries)
        }
        try? context.save()
        dismiss()
    }

    private func refreshRoute() {
        let status = LocalAI.status
        let cloud = AISettings.cloudClient()
        // An open model on the phone is private but not quick; say so up front.
        let local = LocalAI.usesOpenModel
            ? String(localized: "由 \(LocalAI.openModel.title) 在手机上整理，通常要十几秒，文字不会离开手机。")
            : String(localized: "由本机模型整理，文字不会离开手机。")
        switch AISettings.mode {
        case .onDevice:
            routeDescription = status.isAvailable ? local : String(localized: "本机模型不可用：\(status.message)")
        case .cloud:
            routeDescription = cloud.map { String(localized: "由 \($0.provider.displayName)（\($0.model)）整理。") }
                ?? String(localized: "还没有设置云端 AI，点右上角的设置。")
        case .auto:
            if status.isAvailable {
                routeDescription = cloud.map { String(localized: "优先用本机模型整理，处理不了时交给 \($0.provider.displayName)。") }
                    ?? local
            } else {
                routeDescription = cloud.map { String(localized: "由 \($0.provider.displayName) 整理（本机模型不可用）。") }
                    ?? String(localized: "本机模型不可用，请点右上角设置云端 AI。")
            }
        }
    }

    private var consentTitle: String {
        consentProvider.map { String(localized: "发送给 \($0.displayName) 处理？") } ?? ""
    }

    private var consentBinding: Binding<Bool> {
        Binding(get: { consentProvider != nil }, set: { if !$0 { consentProvider = nil } })
    }
}

// MARK: - Pieces

struct MicButton: View {
    let isRecording: Bool
    let isBusy: Bool
    var level: Float = 0
    var size: CGFloat = 48
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isRecording ? Color.red : Color.accentColor)
                if isBusy {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .overlay {
                if isRecording {
                    Circle()
                        .stroke(Color.red.opacity(0.35), lineWidth: 4)
                        .scaleEffect(1 + CGFloat(level) * 0.4)
                }
            }
            .animation(.easeOut(duration: 0.12), value: level)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isRecording ? Text("停止录音") : Text("语音输入"))
    }
}

struct SourceBadge: View {
    let source: CaptureSource
    /// How long the model took, so a slow setup is visible.
    var elapsed: Duration?
    /// Shown when the cloud model was asked to think more than the minimum.
    var thinking: AIThinking?

    var body: some View {
        Label(text, systemImage: source == .onDevice ? "lock.fill" : "cloud.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(.tertiarySystemFill), in: .capsule)
    }

    private var text: String {
        var label = source.label
        if let thinking, thinking != .fast { label += " · " + String(localized: thinking.title) }
        guard let elapsed else { return label }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return label + " · " + String(localized: "\(seconds.formatted(.number.precision(.fractionLength(1)))) 秒")
    }
}

/// One parsed record as an inset-grouped card, like the A design.
struct DraftCard: View {
    @Binding var draft: CaptureDraft
    let onEdit: () -> Void
    let onRemove: () -> Void

    private struct Row: Identifiable {
        let label: LocalizedStringResource
        let value: String
        var uncertain = false
        var emphasized = false
        var id: String { String(localized: label) }
    }

    var body: some View {
        Section {
            HStack(spacing: 10) {
                IconTile(symbol: draft.kind.symbol, color: draft.kind.color, size: 28)
                Text("\(String(localized: draft.kind.title)) · \(draft.title.isEmpty ? String(localized: "未命名") : draft.title)")
                    .font(.headline)
                Spacer()
                Button("移除这条", systemImage: "xmark.circle.fill", action: onRemove)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.borderless)
            }
            .contentShape(.rect)
            .onTapGesture(perform: onEdit)

            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Text(row.label)
                    Spacer()
                    if row.uncertain { UncertainTag() }
                    Text(row.value)
                        .fontWeight(row.emphasized ? .semibold : .regular)
                        .foregroundStyle(row.emphasized ? Color.primary : Color.secondary)
                        .multilineTextAlignment(.trailing)
                }
                .font(.subheadline)
                .contentShape(.rect)
                .onTapGesture(perform: onEdit)
            }

            if draft.kind == .note {
                // A document summary runs longer than a spoken note; show most of it.
                Text(draft.note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(14)
                    .contentShape(.rect)
                    .onTapGesture(perform: onEdit)
            }

            if let existing = draft.existingName {
                Toggle(isOn: $draft.updatesExisting) {
                    VStack(alignment: .leading, spacing: 2) {
                        if draft.kind == .note {
                            Text("追加到已有的「\(existing)」")
                            Text(draft.updatesExisting ? "作为新的一条记录" : "将新建一个笔记")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if draft.kind == .task {
                            Text("已有待办「\(existing)」")
                            Text(draft.updatesExisting ? "同一天的同一件事，不会重复添加" : "将另外新建一条")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("更新已有的「\(existing)」")
                            Text(draft.updatesExisting ? "不会重复添加" : "将另外新建一条")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.subheadline)
            }

            if let problem = draft.problem {
                Button(action: onEdit) {
                    Label(problem, systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var rows: [Row] {
        var rows: [Row] = []
        let isUnsure = { (field: String) in draft.uncertain.contains(field) }
        if draft.kind.hasAmount {
            let money = draft.amount.map { (draft.amountIsApproximate ? String(localized: "约 ") : "") + $0.money(draft.currencyCode) }
            rows.append(Row(label: "金额", value: money ?? String(localized: "未填"), uncertain: isUnsure("amount"), emphasized: true))
        }
        switch draft.kind {
        case .expense, .income:
            rows.append(Row(label: "分类", value: draft.category?.name ?? String(localized: "未分类"), uncertain: isUnsure("category")))
            rows.append(Row(label: "账户", value: draft.account?.name ?? String(localized: "未指定"), uncertain: isUnsure("account")))
            rows.append(Row(label: "时间", value: dateText(hasTime: draft.hasTime), uncertain: isUnsure("date")))
        case .transfer:
            rows.append(Row(label: "账户", value: "\(draft.account?.name ?? "?") → \(draft.toAccount?.name ?? "?")", uncertain: isUnsure("account")))
            rows.append(Row(label: "时间", value: dateText(hasTime: draft.hasTime), uncertain: isUnsure("date")))
        case .task:
            rows.append(Row(label: "时间", value: draft.date == nil ? String(localized: "无日期") : dateText(hasTime: draft.hasTime), uncertain: isUnsure("date")))
            if let recurrence = draft.recurrence {
                rows.append(Row(label: "重复", value: recurrence.summary(anchor: draft.date)))
            }
            if draft.priority != .none {
                rows.append(Row(label: "优先级", value: String(localized: draft.priority.title)))
            }
            if !draft.listName.isEmpty {
                rows.append(Row(label: "清单", value: draft.listName))
            }
            if !draft.quote.isEmpty {
                rows.append(Row(label: "来自笔记", value: "「\(draft.quote)」"))
            }
        case .bill:
            rows.append(Row(label: "下次到期", value: draft.date.map(DayText.dayWithWeekday) ?? String(localized: "未填"), uncertain: isUnsure("date")))
            rows.append(Row(label: "重复", value: draft.recurrence?.summary(anchor: draft.date) ?? String(localized: "一次性")))
            rows.append(Row(label: "提醒", value: ReminderRule.summary(of: draft.reminderRules)))
            if draft.billKind == .creditCard {
                rows.append(Row(label: "还款", value: "\(draft.account?.name ?? String(localized: "未指定")) → \(draft.toAccount?.name ?? String(localized: "信用卡"))"))
            }
        case .receivable, .payable:
            if !draft.counterparty.isEmpty {
                rows.append(Row(label: draft.kind == .receivable ? "谁欠我" : "欠谁", value: draft.counterparty))
            }
            rows.append(Row(label: draft.kind == .receivable ? "预计收到" : "约定付款",
                            value: draft.date.map(DayText.dayWithWeekday) ?? String(localized: "没说")))
            rows.append(Row(label: "分类", value: draft.category?.name ?? String(localized: "未分类"), uncertain: isUnsure("category")))
            rows.append(Row(label: "记到", value: draft.kind == .receivable ? String(localized: "账本 › 应收应付，收到时再记账")
                                                                           : String(localized: "账本 › 应收应付，付出时再记账")))
        case .expiry:
            let value = draft.date.map { date in
                draft.dateIsApproximate ? date.formatted(.dateTime.year().month(.wide)) : date.formatted(.dateTime.year().month().day())
            }
            rows.append(Row(label: "到期日", value: value ?? String(localized: "未填"), uncertain: isUnsure("date")))
            rows.append(Row(label: "提醒", value: ReminderRule.summary(of: draft.reminderRules)))
        case .note:
            let target = if let entry = draft.appendsToEntry {
                String(localized: "「\(entry.note?.displayTitle ?? "")」里附件所在的那条")
            } else if draft.updatesExisting && draft.existingNote != nil {
                "「\(draft.existingNote?.displayTitle ?? "")」"
            } else {
                String(localized: "新笔记「\(draft.title)」")
            }
            rows.append(Row(label: "放进", value: target))
            if draft.isKeyPoint { rows.append(Row(label: "重点", value: String(localized: "★ 标为重点"))) }
        }
        return rows
    }

    private func dateText(hasTime: Bool) -> String {
        draft.date.map { DayText.due($0, hasTime: hasTime) } ?? String(localized: "未填")
    }
}
