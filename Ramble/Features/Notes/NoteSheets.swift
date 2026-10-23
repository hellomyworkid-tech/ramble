import SwiftData
import SwiftUI

// MARK: - Reviewing AI-tidied text

struct NoteReview: Identifiable {
    let id = UUID()
    let original: String
    let organized: OrganizedNote
    var source: CaptureSource = .onDevice
}

/// A suggested reminder the person can accept, edit or drop.
struct ReminderDraft: Identifiable {
    let id = UUID()
    var include = true
    var title: String
    var quote: String
    var date: Date
    var hasTime: Bool
}

struct NoteReviewSheet: View {
    let review: NoteReview
    /// Another go at organizing the same words (「重新整理」); nil hides the buttons.
    var reorganize: ((AIAttempt) async throws -> (OrganizedNote, CaptureSource))?
    /// Text, reminders to add, and whether the entry is a key point.
    let onSave: (String, [ReminderDraft], Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var reminders: [ReminderDraft]
    @State private var isKeyPoint: Bool
    @State private var source: CaptureSource
    @State private var attempt: AIAttempt = .first
    @State private var isReorganizing = false
    @State private var reorganizeError: String?
    @State private var consentProvider: AIProvider?

    init(review: NoteReview, reorganize: ((AIAttempt) async throws -> (OrganizedNote, CaptureSource))? = nil,
         onSave: @escaping (String, [ReminderDraft], Bool) -> Void) {
        self.review = review
        self.reorganize = reorganize
        self.onSave = onSave
        _text = State(initialValue: review.organized.cleanedText)
        _isKeyPoint = State(initialValue: review.organized.markAsKeyPoint)
        _source = State(initialValue: review.source)
        _reminders = State(initialValue: Self.drafts(review.organized))
    }

    private static func drafts(_ organized: OrganizedNote) -> [ReminderDraft] {
        organized.reminders.compactMap { suggestion in
            guard let date = suggestion.dueDate else { return nil }
            return ReminderDraft(title: suggestion.title, quote: suggestion.quote, date: date, hasTime: !suggestion.time.isEmpty)
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("内容", text: $text, axis: .vertical)
                    .lineLimit(3...20)
                Toggle(isOn: $isKeyPoint) {
                    Label("标为重点", systemImage: isKeyPoint ? "star.fill" : "star")
                        .foregroundStyle(isKeyPoint ? ModuleColor.keyPoint : .primary)
                }
                if reorganize != nil {
                    if isReorganizing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在重新整理…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 16) {
                            Button("重新整理", systemImage: "arrow.clockwise") { runReorganize(attempt.next()) }
                            if source == .onDevice, AIAttempt.cloudIsAvailable {
                                Button("用\(AISettings.provider.displayName)整理", systemImage: "cloud") {
                                    runReorganize(attempt.next(forcingCloud: true))
                                }
                            }
                        }
                        .font(.subheadline)
                        .buttonStyle(.borderless)
                    }
                    if let reorganizeError {
                        Text(reorganizeError)
                            .font(.footnote)
                            .foregroundStyle(ModuleColor.warning)
                    }
                }
            } header: {
                Text("整理后的内容")
            } footer: {
                Text(footer)
            }

            if !reminders.isEmpty {
                Section {
                    ForEach($reminders) { $reminder in
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(isOn: $reminder.include) {
                                TextField("提醒内容", text: $reminder.title, axis: .vertical)
                                    .font(.headline)
                                    .lineLimit(1...6)
                            }
                            if reminder.include {
                                DatePicker("时间", selection: $reminder.date,
                                           displayedComponents: reminder.hasTime ? [.date, .hourAndMinute] : [.date])
                            }
                            Text("「\(reminder.quote)」")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("建议设提醒")
                } footer: {
                    Text("保存后会出现在待办里，到时间提醒你；笔记里对应的话会标出来。")
                }
            }

            Section {
                DisclosureGroup("原话") {
                    Text(review.original)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("整理结果")
        .navigationBarTitleDisplayMode(.inline)
        .alert(consentProvider.map { String(localized: "发送给 \($0.displayName) 整理？") } ?? "",
               isPresented: Binding(get: { consentProvider != nil }, set: { if !$0 { consentProvider = nil } }),
               presenting: consentProvider) { _ in
            Button("同意并继续") {
                AISettings.hasCloudConsent = true
                runReorganize(attempt)
            }
            Button("取消", role: .cancel) {}
        } message: { provider in
            Text("这段文字会用你自己的 API Key 直接发送到 \(provider.vendor) 处理，不经过我们的服务器。")
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消", systemImage: "xmark", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", systemImage: "checkmark", role: .confirm) {
                    onSave(text, reminders, isKeyPoint)
                    dismiss()
                }
                .disabled(text.trimmed.isEmpty)
            }
        }
    }
}

extension NoteReviewSheet {
    /// Replaces the text and suggestions with a fresh result; a key point stays marked.
    fileprivate func runReorganize(_ next: AIAttempt) {
        guard let reorganize, !isReorganizing else { return }
        attempt = next
        isReorganizing = true
        reorganizeError = nil
        Task {
            defer { isReorganizing = false }
            do {
                let (organized, newSource) = try await reorganize(next)
                text = organized.cleanedText
                reminders = Self.drafts(organized)
                isKeyPoint = isKeyPoint || organized.markAsKeyPoint
                source = newSource
            } catch AIError.needsConsent(let provider) {
                consentProvider = provider
            } catch {
                reorganizeError = error.localizedDescription
            }
        }
    }

    fileprivate var footer: String {
        var parts = [NoteTidyStyle.current == .fluent
                     ? String(localized: "按意思理顺了语句，事实和数字都保留着。不满意可以直接改，或展开原话对照。")
                     : String(localized: "只去掉了口头禅和重复，事实都保留着。不满意可以直接改。")]
        if review.organized.markAsKeyPoint {
            parts.append(String(localized: "你说了要标重点，已经替你打开。"))
        }
        return parts.joined(separator: "")
    }
}

// MARK: - A reminder on a sentence

struct ReminderTarget: Identifiable {
    let id = UUID()
    let entry: NoteEntry
    let quote: String
}

/// Lists the entry's sentences; picking one opens the reminder form on it.
/// An entry with a single sentence goes straight to the form.
struct SentencePicker: View {
    let entry: NoteEntry
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let sentences = entry.sentences
        if sentences.count == 1, let only = sentences.first {
            ReminderFromTextSheet(target: ReminderTarget(entry: entry, quote: only))
        } else {
            List {
                Section {
                    ForEach(Array(sentences.enumerated()), id: \.offset) { _, sentence in
                        NavigationLink {
                            ReminderFromTextSheet(target: ReminderTarget(entry: entry, quote: sentence), onSaved: onDone)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: "bell")
                                    .foregroundStyle(ModuleColor.notes)
                                Text(sentence)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                    }
                } footer: {
                    Text("选一句话设提醒。会生成一条待办，到时间通知你，并和这句话关联。")
                }
            }
            .navigationTitle("给哪句话设提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", systemImage: "xmark", role: .cancel) { dismiss() }
                }
            }
        }
    }
}

/// Marks sentences of an entry with a highlighter; tap again to remove the mark.
struct HighlightPicker: View {
    let entry: NoteEntry
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Toggle(isOn: keyPointBinding) {
                    Label("整条标为重点", systemImage: "star.fill")
                        .foregroundStyle(ModuleColor.keyPoint)
                }
                .tint(ModuleColor.keyPoint)
            }
            Section {
                ForEach(Array(entry.sentences.enumerated()), id: \.offset) { _, sentence in
                    Button {
                        entry.toggleHighlight(sentence)
                        save()
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: entry.isHighlighted(sentence) ? "highlighter" : "circle")
                                .symbolRenderingMode(.monochrome)
                                .foregroundStyle(entry.isHighlighted(sentence) ? ModuleColor.keyPoint : Color.secondary)
                                .frame(width: 20)
                            Text(sentence)
                                .fontWeight(entry.isHighlighted(sentence) ? .semibold : .regular)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .padding(.horizontal, entry.isHighlighted(sentence) ? 3 : 0)
                                .background(entry.isHighlighted(sentence) ? ModuleColor.highlighter : .clear,
                                            in: .rect(cornerRadius: 3))
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(entry.isHighlighted(sentence) ? .isSelected : [])
                }
            } header: {
                Text("高亮句子")
            } footer: {
                Text("点一句话高亮，再点一次取消。要高亮半句话，可以在「编辑」里选中文字。")
            }
        }
        .navigationTitle("标重点")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成", systemImage: "checkmark", role: .confirm) { dismiss() }
            }
        }
    }

    private var keyPointBinding: Binding<Bool> {
        Binding(get: { entry.isKeyPoint }, set: { entry.isKeyPoint = $0; save() })
    }

    private func save() {
        entry.note?.updatedAt = .now
        try? context.save()
    }
}

/// Creates a to-do tied to a sentence in a note entry.
struct ReminderFromTextSheet: View {
    let target: ReminderTarget
    /// Set when pushed inside another sheet, which this closes on save.
    var onSaved: (() -> Void)?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var date: Date
    @State private var hasTime: Bool
    @State private var recurrence: Recurrence?

    init(target: ReminderTarget, onSaved: (() -> Void)? = nil) {
        self.target = target
        self.onSaved = onSaved
        let guess = Self.detectedDate(in: target.quote)
        _title = State(initialValue: Self.defaultTitle(from: target.quote))
        _date = State(initialValue: guess?.date ?? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)) ?? .now)
        _hasTime = State(initialValue: guess?.hasTime ?? false)
    }

    var body: some View {
        Form {
            Section {
                TextField("要提醒你做什么", text: $title, axis: .vertical)
                    .font(.headline)
                    .lineLimit(2...8)
            } header: {
                Text("提醒内容")
            } footer: {
                Text("原句：「\(target.quote)」")
            }
            Section {
                DatePicker("日期", selection: $date, displayedComponents: .date)
                Toggle("时间", isOn: $hasTime.animation())
                if hasTime {
                    DatePicker("时间", selection: $date, displayedComponents: .hourAndMinute)
                }
                RecurrenceField(recurrence: $recurrence, anchor: date)
            } footer: {
                Text(hasTime ? "到时间会通知你。" : "当天 9:00 通知你。")
            }
        }
        .navigationTitle("设提醒")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if onSaved == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", systemImage: "xmark", role: .cancel) { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", systemImage: "checkmark", role: .confirm, action: save)
                    .disabled(title.trimmed.isEmpty)
            }
        }
    }

    private func save() {
        let due = hasTime ? date : Calendar.current.startOfDay(for: date)
        let task = TaskItem(title: title.trimmed, dueDate: due, hasDueTime: hasTime)
        task.recurrence = recurrence?.normalized(anchor: due)
        context.insert(task)
        task.sourceEntry = target.entry
        task.sourceQuote = target.quote
        target.entry.note?.updatedAt = .now
        try? context.save()
        if let onSaved { onSaved() } else { dismiss() }
    }

    /// The whole sentence without its closing punctuation; the person shortens it if they like.
    static func defaultTitle(from quote: String) -> String {
        quote.trimmingCharacters(in: CharacterSet(charactersIn: "。！？!?；;，,. \n"))
    }

    /// A date written in the sentence, when the system can read one.
    static func detectedDate(in text: String, now: Date = .now) -> (date: Date, hasTime: Bool)? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let date = match.date, date > now
        else { return nil }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (date, !(parts.hour == 12 && parts.minute == 0) && !(parts.hour == 0 && parts.minute == 0))
    }
}

// MARK: - Editing an entry

struct NoteEntryEditor: View {
    let entry: NoteEntry
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var selection: TextSelection?
    @State private var date: Date
    @State private var attachments: [DraftAttachment]
    @State private var reminderTarget: ReminderTarget?
    @State private var highlights: [String]
    @State private var isKeyPoint: Bool

    init(entry: NoteEntry) {
        self.entry = entry
        _highlights = State(initialValue: entry.highlights)
        _isKeyPoint = State(initialValue: entry.isKeyPoint)
        _text = State(initialValue: entry.text)
        _date = State(initialValue: entry.date)
        _attachments = State(initialValue: DraftAttachment.drafts(from: entry.attachments))
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text, selection: $selection)
                    .frame(minHeight: 180)
                Button("给选中的文字设提醒", systemImage: "bell") {
                    reminderTarget = ReminderTarget(entry: entry, quote: selectedText)
                }
                .disabled(selectedText.isEmpty)
                Button(highlights.contains(selectedText) ? "取消高亮选中的文字" : "高亮选中的文字", systemImage: "highlighter") {
                    if highlights.contains(selectedText) {
                        highlights.removeAll { $0 == selectedText }
                    } else {
                        highlights.append(selectedText)
                    }
                }
                .disabled(selectedText.isEmpty)
                Toggle("整条标为重点", systemImage: "star", isOn: $isKeyPoint)
                    .tint(ModuleColor.keyPoint)
            } footer: {
                Text(highlights.isEmpty
                     ? String(localized: "在上面选中文字，可以设提醒或高亮。")
                     : String(localized: "已高亮：\(highlights.map { String(localized: "「\($0)」") }.joined(separator: " "))"))
            }

            Section {
                DatePicker("记录时间", selection: $date)
            }

            AttachmentsSection(title: "图片和文件", attachments: $attachments, allowsDocuments: true)
        }
        .navigationTitle("编辑记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消", systemImage: "xmark", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", systemImage: "checkmark", role: .confirm, action: save)
            }
        }
        .sheet(item: $reminderTarget) { target in
            NavigationStack { ReminderFromTextSheet(target: target) }
        }
    }

    private var selectedText: String {
        guard let selection, case .selection(let range) = selection.indices else { return "" }
        guard range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex else { return "" }
        return String(text[range]).trimmed
    }

    private func save() {
        if entry.text != text {
            entry.text = text.trimmed
            entry.editedAt = .now
        }
        entry.date = date
        entry.isKeyPoint = isKeyPoint
        // Set after the text, so passages edited away are dropped.
        entry.highlights = highlights
        DraftAttachment.sync(attachments, replacing: entry.attachments, in: context) { $0.noteEntry = entry }
        entry.note?.updatedAt = .now
        try? context.save()
        NoteIndexer.indexAttachments(of: entry)
        dismiss()
    }
}
