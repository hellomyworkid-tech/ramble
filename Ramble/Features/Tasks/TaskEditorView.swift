import SwiftData
import SwiftUI

struct TaskEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router

    let task: TaskItem?
    /// Set when pushed inside another flow (the capture sheet); called after saving.
    var onFinish: (() -> Void)?
    /// False when opened from the note itself, where a link back to it would go nowhere.
    let showsNoteLink: Bool

    private struct DraftSubtask: Identifiable {
        let id = UUID()
        var title: String
        var isDone: Bool
        var model: Subtask?
    }

    @State private var title: String
    @State private var notes: String
    @State private var hasDate: Bool
    @State private var hasTime: Bool
    @State private var dueDate: Date
    @State private var priority: TaskPriority
    @State private var listName: String
    @State private var recurrence: Recurrence?
    @State private var reminderMinutes: [Int]
    @State private var subtasks: [DraftSubtask]
    @State private var newSubtask = ""
    @State private var confirmDelete = false
    @FocusState private var titleFocused: Bool

    init(task: TaskItem?, showsNoteLink: Bool = true, onFinish: (() -> Void)? = nil) {
        self.task = task
        self.showsNoteLink = showsNoteLink
        self.onFinish = onFinish
        _title = State(initialValue: task?.title ?? "")
        _notes = State(initialValue: task?.notes ?? "")
        _hasDate = State(initialValue: task?.dueDate != nil)
        _hasTime = State(initialValue: task?.hasDueTime ?? false)
        _dueDate = State(initialValue: task?.dueDate ?? Self.nextFullHour())
        _priority = State(initialValue: task?.priority ?? .none)
        _listName = State(initialValue: task?.listName ?? "")
        _recurrence = State(initialValue: task?.recurrence)
        _reminderMinutes = State(initialValue: task?.reminderMinutes ?? [0])
        _subtasks = State(initialValue: (task?.sortedSubtasks ?? []).map { DraftSubtask(title: $0.title, isDone: $0.isDone, model: $0) })
    }

    var body: some View {
        Form {
            Section {
                TextField("标题", text: $title, axis: .vertical)
                    .font(.headline)
                    .lineLimit(1...4)
                    .focused($titleFocused)
                TextField("备注", text: $notes, axis: .vertical)
                    .lineLimit(1...5)
            }

            Section {
                Toggle(isOn: $hasDate.animation()) {
                    Label("日期", systemImage: "calendar")
                }
                if hasDate {
                    DatePicker("日期", selection: $dueDate, displayedComponents: .date)
                    Toggle(isOn: $hasTime.animation()) {
                        Label("时间", systemImage: "clock")
                    }
                    if hasTime {
                        DatePicker("时间", selection: $dueDate, displayedComponents: .hourAndMinute)
                    }
                    RecurrenceField(recurrence: $recurrence, anchor: dueDate)
                    Picker(selection: $reminderMinutes) {
                        ForEach(reminderOptions, id: \.minutes) { option in
                            Text(option.title).tag(option.minutes)
                        }
                    } label: {
                        Label("提醒", systemImage: "bell")
                    }
                }
            }

            Section {
                Picker("优先级", selection: $priority) {
                    ForEach(TaskPriority.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("清单") {
                    TextField("如 工作、家庭", text: $listName)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("子任务") {
                ForEach($subtasks) { $item in
                    HStack(spacing: 10) {
                        Button {
                            item.isDone.toggle()
                        } label: {
                            Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.isDone ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(item.isDone ? "标记为未完成" : "完成"))
                        TextField("子任务", text: $item.title)
                    }
                }
                .onDelete { subtasks.remove(atOffsets: $0) }

                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.tint)
                    TextField("添加子任务", text: $newSubtask)
                        .onSubmit(addSubtask)
                        .submitLabel(.next)
                }
            }

            if let task, let note = task.sourceEntry?.note {
                Section("来自笔记") {
                    if !task.sourceQuote.isEmpty {
                        Text("「\(task.sourceQuote)」")
                            .foregroundStyle(.secondary)
                    }
                    if showsNoteLink {
                        Button("打开「\(note.displayTitle)」", systemImage: "note.text") {
                            router.open(note)
                            dismiss()
                        }
                    }
                }
            }

            if task != nil {
                Section {
                    Button("删除待办", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(task == nil ? "新建待办" : "编辑待办")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if onFinish == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", systemImage: "xmark", role: .cancel) { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", systemImage: "checkmark", role: .confirm, action: save)
                    .disabled(title.trimmed.isEmpty)
            }
        }
        .confirmationDialog("删除这条待办？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive, action: delete)
        }
        .onAppear {
            if task == nil { titleFocused = true }
        }
    }

    private struct ReminderOption {
        let minutes: [Int]
        let title: String
    }

    private var reminderOptions: [ReminderOption] {
        var options: [ReminderOption]
        if hasTime {
            options = [
                .init(minutes: [], title: String(localized: "不提醒")),
                .init(minutes: [0], title: String(localized: "准时")),
                .init(minutes: [5], title: String(localized: "提前 5 分钟")),
                .init(minutes: [15], title: String(localized: "提前 15 分钟")),
                .init(minutes: [30], title: String(localized: "提前 30 分钟")),
                .init(minutes: [60], title: String(localized: "提前 1 小时")),
                .init(minutes: [1440], title: String(localized: "提前 1 天")),
            ]
        } else {
            options = [
                .init(minutes: [], title: String(localized: "不提醒")),
                .init(minutes: [0], title: String(localized: "当天 9:00")),
                .init(minutes: [1440], title: String(localized: "前一天 9:00")),
            ]
        }
        // Keep a value set elsewhere (e.g. by the AI) selectable.
        if !options.contains(where: { $0.minutes == reminderMinutes }) {
            let text = reminderMinutes.map { ReminderPlanner.durationText(minutes: $0) }.joined(separator: "、")
            options.append(.init(minutes: reminderMinutes, title: String(localized: "提前 \(text)")))
        }
        return options
    }

    private static func nextFullHour() -> Date {
        let calendar = Calendar.current
        let hour = calendar.dateInterval(of: .hour, for: .now)?.end ?? .now
        return hour
    }

    private func addSubtask() {
        let text = newSubtask.trimmed
        guard !text.isEmpty else { return }
        subtasks.append(DraftSubtask(title: text, isDone: false, model: nil))
        newSubtask = ""
    }

    private func save() {
        addSubtask()
        let target = task ?? TaskItem(title: title.trimmed)
        if task == nil { context.insert(target) }

        target.title = title.trimmed
        target.notes = notes.trimmed
        if hasDate {
            target.dueDate = hasTime ? dueDate : Calendar.current.startOfDay(for: dueDate)
            target.hasDueTime = hasTime
            target.recurrence = recurrence?.normalized(anchor: dueDate)
        } else {
            target.dueDate = nil
            target.hasDueTime = false
            target.recurrence = nil
        }
        target.priority = priority
        target.listName = listName.trimmed
        target.reminderMinutes = reminderMinutes

        let kept = subtasks.filter { !$0.title.trimmed.isEmpty }
        let keptIDs = Set(kept.compactMap { $0.model?.persistentModelID })
        for existing in target.subtasks ?? [] where !keptIDs.contains(existing.persistentModelID) {
            context.delete(existing)
        }
        for (index, draft) in kept.enumerated() {
            let subtask = draft.model ?? Subtask(title: draft.title.trimmed, order: index)
            if draft.model == nil {
                context.insert(subtask)
                subtask.task = target
            }
            subtask.title = draft.title.trimmed
            subtask.isDone = draft.isDone
            subtask.order = index
        }

        finish()
    }

    private func delete() {
        if let task { context.delete(task) }
        finish()
    }

    private func finish() {
        if let onFinish { onFinish() } else { dismiss() }
    }
}
