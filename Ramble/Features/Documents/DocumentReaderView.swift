import SwiftData
import SwiftUI

/// "AI 读一下": reads photos and files on the phone, has the AI summarize them, and shows
/// the result on the same review cards as "记一下". Nothing is saved until the person says so.
struct DocumentReaderView: View {
    let destination: DocumentDestination
    var showsCancel = true
    /// Called after saving instead of dismissing, for callers that close more than this view.
    var onSaved: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(AppSettings.baseCurrencyKey) private var baseCurrency = AppSettings.defaultBaseCurrency
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(filter: #Predicate<Bill> { $0.isActive }) private var bills: [Bill]
    @Query(filter: #Predicate<ExpiryItem> { !$0.isArchived }) private var expiries: [ExpiryItem]
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]
    @Query(filter: #Predicate<TaskItem> { !$0.isCompleted }) private var openTasks: [TaskItem]

    private enum Phase {
        case picking, recognizing, poorText, reading, review, failed
    }

    @State private var files: [DraftAttachment]
    /// What the person typed or said with the files; the AI follows it.
    @State private var request: String
    @State private var phase: Phase
    @State private var progress = ""
    @State private var pageCounts: [UUID: Int] = [:]
    @State private var drafts: [CaptureDraft] = []
    @State private var source: CaptureSource?
    @State private var elapsed: Duration?
    @State private var thinking: AIThinking?
    @State private var usedOriginals = false
    @State private var lastAttemptUsedOriginals = false
    @State private var errorMessage: String?
    @State private var consentProvider: AIProvider?
    @State private var confirmsOriginals = false
    @State private var editingDraft: CaptureDraft.ID?
    @State private var showsAISettings = false
    @State private var picker = AttachmentPickerState()
    @State private var preview: PreviewFile?
    @State private var didStart = false
    /// The cloud provider that could look at the files; refreshed after visiting AI settings.
    @State private var originalsProvider = DocumentReader.providerForOriginals

    init(files: [DraftAttachment], destination: DocumentDestination, request: String = "", showsCancel: Bool = true,
         onSaved: (() -> Void)? = nil) {
        self.destination = destination
        self.showsCancel = showsCancel
        self.onSaved = onSaved
        _files = State(initialValue: files)
        _request = State(initialValue: request.trimmed)
        _phase = State(initialValue: files.isEmpty ? .picking : .recognizing)
    }

    var body: some View {
        Group {
            switch phase {
            case .picking: pickingForm
            case .recognizing, .reading: progressView
            case .poorText: poorTextForm
            case .review: reviewForm
            case .failed: failedForm
            }
        }
        .navigationTitle(phase == .review ? "读取结果" : "AI 读文件")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCancel {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", systemImage: "xmark", role: .cancel) { dismiss() }
                }
            }
        }
        .navigationDestination(item: $editingDraft) { id in
            if let index = drafts.firstIndex(where: { $0.id == id }) {
                DraftEditorView(draft: $drafts[index], categories: categories, accounts: accounts, notes: notes)
            }
        }
        .navigationDestination(isPresented: $showsAISettings) {
            AISettingsView()
        }
        .attachmentPickers(state: $picker) { files.append($0) }
        .attachmentPreview($preview)
        .alert(consentProvider.map { String(localized: "发送给 \($0.displayName) 处理？") } ?? "",
               isPresented: consentBinding, presenting: consentProvider) { _ in
            Button("同意并继续") {
                AISettings.hasCloudConsent = true
                Task { await read(usingOriginals: false) }
            }
            Button("取消", role: .cancel) {}
        } message: { provider in
            Text("识别出的文字会用你自己的 API Key 直接发送到 \(provider.vendor) 处理，不经过我们的服务器。证件号会先在手机上隐去。")
        }
        .confirmationDialog(originalsTitle, isPresented: $confirmsOriginals, titleVisibility: .visible) {
            Button("发送原件") { Task { await read(usingOriginals: true) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("原件里的全部内容（包括姓名、证件号）都会用你的 API Key 发送到 \(AISettings.provider.vendor)。")
        }
        .interactiveDismissDisabled(phase == .review)
        .onChange(of: showsAISettings) { _, showing in
            if !showing { originalsProvider = DocumentReader.providerForOriginals }
        }
        .task {
            guard !didStart, phase == .recognizing else { return }
            didStart = true
            await recognize()
        }
    }

    // MARK: - Picking (from "记一下")

    private var pickingForm: some View {
        Form {
            Section {
                if !files.isEmpty { fileStrip }
                AttachmentAddButtons(picker: $picker, addPhotoTitle: "照片", allowsDocuments: true)
                if let message = picker.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("体检报告、合同、保修卡、发票，照片、PDF、Word、Excel 都可以。多页的纸质文件可以一次选几张照片。文字先在手机上识别。")
            }
            Section {
                TextField("给 AI 的话（可不填）", text: $request, axis: .vertical)
                    .lineLimit(1...4)
            } footer: {
                Text("比如：这是上个月的电费单，记一笔；只记保修到期日；放进「装修记录」。")
            }
            Section {
                Button {
                    Task { await recognize() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text("AI 读一下")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(files.isEmpty)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
    }

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
                    .contextMenu {
                        if phase == .picking {
                            Button("移除", systemImage: "trash", role: .destructive) {
                                files.removeAll { $0.id == file.id }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Working

    private var progressView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(phase == .recognizing ? "正在手机上识别文字…" : "AI 正在读…")
                .font(.headline)
            Text(phase == .recognizing ? progress : readingDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .monospacedDigit()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var readingDescription: String {
        if lastAttemptUsedOriginals {
            return String(localized: "\(AISettings.provider.displayName) 正在看原件，较长的文件需要一两分钟。")
        }
        return String(localized: "只发送识别出的文字，证件号已隐去。")
    }

    // MARK: - Poor recognition

    private var poorTextForm: some View {
        Form {
            Section {
                fileStrip
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(recognizedCount == 0 ? "没有认出文字" : "只认出了 \(recognizedCount) 个字")
                            .font(.headline)
                        Text(recognizedCount == 0 ? "可能拍得太模糊，或者这不是一份文件。" : "可能是照片模糊、表格复杂或者是手写的。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "text.viewfinder")
                        .foregroundStyle(ModuleColor.warning)
                }
            }
            if let provider = originalsProvider {
                Section {
                    Button("把原件发给 \(provider.displayName) 读", systemImage: "eye") { confirmsOriginals = true }
                } footer: {
                    Text("\(provider.displayName) 可以直接看图片和 PDF，表格和手写的识别更准。")
                }
            } else {
                Section {
                    Button("打开 AI 设置", systemImage: "gearshape") { showsAISettings = true }
                } footer: {
                    Text("设置一个云端 AI（Claude、ChatGPT 或 Gemini）后，可以让它直接看原件。")
                }
            }
            Section {
                if recognizedCount > 0 {
                    Button("就用认出的文字") { Task { await read(usingOriginals: false) } }
                } else if !request.isEmpty {
                    Button("按我写的话来记") { Task { await read(usingOriginals: false) } }
                }
                if case .anywhere = destination {
                    Button("重新选择") { phase = .picking }
                }
            }
        }
    }

    // MARK: - Review

    private var reviewForm: some View {
        Form {
            Section {
                fileStrip
                if !request.isEmpty {
                    Label(request, systemImage: "text.bubble")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(usedOriginals ? "AI 看了原件" : "读了 \(files.count) 个文件")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("AI 只摘录文件里写了的内容，不做诊断或建议。数字请对照原件核对。")
                    Spacer(minLength: 8)
                    if let source { SourceBadge(source: source, elapsed: elapsed, thinking: thinking) }
                }
            }

            ForEach($drafts) { $draft in
                DraftCard(draft: $draft,
                          onEdit: { editingDraft = draft.id },
                          onRemove: { remove(draft.id) })
            }

            if !usedOriginals, files.contains(where: canSendOriginal), let provider = originalsProvider {
                Section {
                    Button("识别不准？让 \(provider.displayName) 看原件重读", systemImage: "eye") { confirmsOriginals = true }
                        .font(.subheadline)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { saveBar }
    }

    private var saveBar: some View {
        VStack(spacing: 6) {
            if let problem = drafts.lazy.compactMap(\.problem).first {
                Text("还有一条\(problem)，点那一条补上")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if !DocumentImport.keepsFiles(drafts, destination: destination) {
                Text("去掉了笔记，这些文件不会保存")
                    .font(.footnote)
                    .foregroundStyle(ModuleColor.warning)
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

    // MARK: - Failure

    private var failedForm: some View {
        Form {
            Section {
                Label(errorMessage ?? String(localized: "没能读取。"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(ModuleColor.warning)
            }
            Section {
                Button("重试") { Task { await read(usingOriginals: lastAttemptUsedOriginals) } }
                    .disabled(documentFiles.isEmpty)
                Button("打开 AI 设置") { showsAISettings = true }
            }
        }
    }

    // MARK: - Actions

    /// Step 1, on the phone: text from every photo and page.
    private func recognize() async {
        phase = .recognizing
        errorMessage = nil
        let readable = files.indices.filter { files[$0].data != nil && isReadable(files[$0]) }
        guard !readable.isEmpty else {
            fail(String(localized: "暂时读不了这种文件。旧版的 .doc、.xls 和 Pages、Numbers 文件可以先导出成 PDF 或新版 Word、Excel 再试。"))
            return
        }
        let counts = readable.map { DocumentText.pageCount(of: files[$0].data!, kind: files[$0].kind, contentType: files[$0].contentType) }
        let total = counts.reduce(0, +)
        var done = 0
        for (index, count) in zip(readable, counts) {
            guard let data = files[index].data else { continue }
            pageCounts[files[index].id] = count
            let before = done
            progress = String(localized: "第 \(before + 1)/\(total) 页")
            let text = await DocumentText.read(data, kind: files[index].kind, contentType: files[index].contentType,
                                               fileName: files[index].fileName) { page in
                progress = String(localized: "第 \(min(before + page + 1, total))/\(total) 页")
            }
            files[index].recognizedText = text
            done += count
        }

        let documents = documentFiles
        let allText = documents.map(\.text).joined(separator: "\n")
        if DocumentText.isPoor(allText, pages: total) {
            if documents.contains(where: { $0.original != nil }) {
                phase = .poorText
                return
            }
            // A photo of a thing rather than a page: the person's words can still say what to record.
            if recognizedCount == 0, request.trimmed.isEmpty {
                fail(String(localized: "没有认出文字。"))
                return
            }
        }
        await read(usingOriginals: false)
    }

    /// Step 2: the AI reads the text (or, if the person agreed, the files themselves).
    private func read(usingOriginals: Bool) async {
        phase = .reading
        errorMessage = nil
        lastAttemptUsedOriginals = usingOriginals
        do {
            let started = ContinuousClock.now
            defer { elapsed = ContinuousClock.now - started }
            let outcome = try await DocumentReader.read(documentFiles, context: makeContext(), noteTitle: destination.noteTitle,
                                                        usesOriginals: usingOriginals, request: request)
            var parsed = outcome.capture.items.map { item in
                var draft = CaptureDraft(item: item, categories: categories, accounts: accounts, baseCurrency: baseCurrency)
                draft.linkExisting(bills: bills, expiries: expiries, notes: notes, tasks: openTasks)
                return draft
            }
            DocumentImport.prepare(&parsed, for: destination)
            drafts = parsed
            source = outcome.source
            thinking = outcome.thinking
            usedOriginals = usingOriginals
            phase = .review
        } catch AIError.needsConsent(let provider) {
            fail(AIError.needsConsent(provider).localizedDescription)
            consentProvider = provider
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        phase = .failed
    }

    private func remove(_ id: CaptureDraft.ID) {
        withAnimation { drafts.removeAll { $0.id == id } }
    }

    private func save() {
        DocumentImport.save(drafts, files: files, destination: destination, in: context, baseCurrency: baseCurrency)
        try? context.save()
        if let onSaved { onSaved() } else { dismiss() }
    }

    // MARK: - Helpers

    private var documentFiles: [DocumentFile] {
        files.compactMap { file in
            guard let data = file.data, isReadable(file) else { return nil }
            return DocumentFile(fileName: file.fileName, kind: file.kind, contentType: file.contentType,
                                text: file.recognizedText, pages: pageCounts[file.id] ?? 1, data: data)
        }
    }

    private var recognizedCount: Int {
        documentFiles.reduce(0) { $0 + DocumentText.meaningfulCount($1.text) }
    }

    private func isReadable(_ file: DraftAttachment) -> Bool {
        DocumentText.isReadable(kind: file.kind, contentType: file.contentType, fileName: file.fileName)
    }

    private func canSendOriginal(_ file: DraftAttachment) -> Bool {
        DocumentText.canSendOriginal(kind: file.kind, contentType: file.contentType)
    }

    private var originalsTitle: String {
        String(localized: "把原件发给 \(AISettings.provider.displayName) 读？")
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

    private var consentBinding: Binding<Bool> {
        Binding(get: { consentProvider != nil }, set: { if !$0 { consentProvider = nil } })
    }
}
