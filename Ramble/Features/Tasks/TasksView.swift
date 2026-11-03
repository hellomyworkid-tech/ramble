import SwiftData
import SwiftUI

struct TasksView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case today, upcoming, all, completed

        var id: String { rawValue }

        var title: LocalizedStringResource {
            switch self {
            case .today: "今天"
            case .upcoming: "计划"
            case .all: "全部"
            case .completed: "已完成"
            }
        }
    }

    private struct Group: Identifiable {
        let id: String
        let title: String
        let tasks: [TaskItem]
    }

    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Query private var queried: [TaskItem]
    @State private var filter: Filter = .today
    @State private var query = ""
    @State private var editingTask: TaskItem?
    @State private var isCreating = false
    /// The to-do a reminder led to, tinted for a moment.
    @State private var spotlit: PersistentIdentifier?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if !isSearching {
                        Section {
                            Picker("范围", selection: $filter) {
                                ForEach(Filter.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        }
                    }

                    ForEach(groups) { group in
                        Section(group.title) {
                            ForEach(group.tasks) { task in
                                TaskRow(task: task)
                                    .contentShape(.rect)
                                    .onTapGesture { editingTask = task }
                                    .swipeActions {
                                        Button("删除", systemImage: "trash", role: .destructive) {
                                            PendingDeletion.shared.delete([task], message: String(localized: "已删除「\(task.title)」"), in: context)
                                        }
                                    }
                                    .id(task.persistentModelID)
                                    .spotlit(spotlit == task.persistentModelID, ModuleColor.tasks)
                            }
                        }
                    }
                }
                .overlay {
                    if groups.isEmpty {
                        if isSearching {
                            ContentUnavailableView.search(text: query)
                        } else {
                            ContentUnavailableView(emptyTitle, systemImage: "checkmark.circle", description: Text("点右上角 +，或者在下方直接说出来"))
                        }
                    }
                }
                .animation(.default, value: filter)
                .searchable(text: $query, prompt: Text("搜索待办"))
                .deletionUndoBar()
                .navigationTitle("待办")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("新建待办", systemImage: "plus") { isCreating = true }
                    }
                }
                .sheet(isPresented: $isCreating) {
                    NavigationStack { TaskEditorView(task: nil) }
                }
                .sheet(item: $editingTask) { task in
                    NavigationStack { TaskEditorView(task: task) }
                }
                .onChange(of: router.focus, initial: true) { showFocusedTask(proxy) }
            }
        }
    }

    /// A tapped reminder shows its to-do in the list, with the checkbox at hand, rather than
    /// opening it for editing: by the time the reminder is tapped, it has often just been done.
    private func showFocusedTask(_ proxy: ScrollViewProxy) {
        guard case .task(let id) = router.focus else { return }
        router.focus = nil
        guard let task = tasks.first(where: { $0.persistentModelID == id }) else { return }
        query = ""
        filter = task.isCompleted ? .completed : task.isDueByEndOfToday() ? .today : .upcoming
        proxy.spotlight(id, on: $spotlit)
    }

    /// Every to-do, less one waiting to be deleted.
    private var tasks: [TaskItem] {
        queried.filter { !PendingDeletion.shared.hides($0) }
    }

    private var isSearching: Bool { !query.trimmed.isEmpty }

    private var emptyTitle: LocalizedStringResource {
        switch filter {
        case .today: "今天没有待办"
        case .upcoming: "没有计划中的待办"
        case .all: "还没有待办"
        case .completed: "还没有完成的待办"
        }
    }

    private var groups: [Group] {
        let calendar = Calendar.current
        if isSearching {
            // Every filter at once: what's still to do first, then what's done, latest first.
            let found = tasks.filter { $0.matches(query) }
            let open = found.filter { !$0.isCompleted }.sorted(by: Self.dueOrder)
            let done = found.filter(\.isCompleted).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            return [
                Group(id: "found-open", title: String(localized: "未完成"), tasks: open),
                Group(id: "found-done", title: String(localized: "已完成"), tasks: done),
            ].filter { !$0.tasks.isEmpty }
        }
        let open = tasks.filter { !$0.isCompleted }.sorted(by: Self.dueOrder)
        switch filter {
        case .today:
            let overdue = open.filter { $0.isOverdue() }
            let today = open.filter { $0.isDueByEndOfToday() && !$0.isOverdue() }
            return [
                Group(id: "overdue", title: String(localized: "已逾期"), tasks: overdue),
                Group(id: "today", title: String(localized: "今天"), tasks: today),
            ].filter { !$0.tasks.isEmpty }
        case .upcoming:
            let later = open.filter { !$0.isDueByEndOfToday() }
            let dated = Dictionary(grouping: later.filter { $0.dueDate != nil }) { calendar.startOfDay(for: $0.dueDate!) }
            var result = dated.keys.sorted().map { day in
                Group(id: day.formatted(.iso8601), title: DayText.dayWithWeekday(day), tasks: dated[day] ?? [])
            }
            let undated = later.filter { $0.dueDate == nil }
            if !undated.isEmpty {
                result.append(Group(id: "undated", title: String(localized: "无日期"), tasks: undated))
            }
            return result
        case .all:
            let byList = Dictionary(grouping: open) { $0.listName }
            return byList.keys.sorted { lhs, rhs in
                // Unlisted tasks go last.
                if lhs.isEmpty != rhs.isEmpty { return !lhs.isEmpty }
                return lhs < rhs
            }
            .map { name in
                Group(id: "list-\(name)", title: name.isEmpty ? String(localized: "未分类") : name, tasks: byList[name] ?? [])
            }
        case .completed:
            let done = tasks.filter(\.isCompleted).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            return done.isEmpty ? [] : [Group(id: "done", title: String(localized: "已完成"), tasks: done)]
        }
    }

    nonisolated private static func dueOrder(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        let left = lhs.dueDate ?? .distantFuture
        let right = rhs.dueDate ?? .distantFuture
        if left != right { return left < right }
        return lhs.priorityRaw > rhs.priorityRaw
    }
}

struct TaskRow: View {
    let task: TaskItem

    var body: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.snappy) { task.toggleCompletion() }
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(task.isCompleted ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isCompleted ? Text("标记为未完成：\(task.title)") : Text("完成：\(task.title)"))

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(task.isOverdue() ? Color.red : Color.secondary)
                }
            }

            Spacer(minLength: 0)

            if task.priority != .none, !task.isCompleted {
                Text(task.priority.marks)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.red)
                    .accessibilityLabel(Text("优先级 \(String(localized: task.priority.title))"))
            }
        }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let dueDate = task.dueDate {
            parts.append(DayText.due(dueDate, hasTime: task.hasDueTime))
        }
        if let recurrence = task.recurrence {
            parts.append(recurrence.summary(anchor: task.dueDate))
        }
        if !task.listName.isEmpty {
            parts.append(task.listName)
        }
        if let note = task.sourceEntry?.note {
            parts.append(String(localized: "来自 \(note.displayTitle)"))
        }
        let subtasks = task.subtasks ?? []
        if !subtasks.isEmpty {
            parts.append("\(subtasks.filter(\.isDone).count)/\(subtasks.count)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
