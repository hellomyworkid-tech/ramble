import SwiftData
import SwiftUI

/// The 项目 line under the month's figures, once there is a project.
struct ProjectsSummaryRow: View {
    @Query private var projects: [Project]

    var body: some View {
        if !projects.isEmpty {
            NavigationLink {
                ProjectsView()
            } label: {
                HStack(spacing: 12) {
                    IconTile(symbol: "folder", color: ModuleColor.money)
                    Text(ScreenName.projects)
                    Spacer(minLength: 8)
                    let active = projects.filter { !$0.isFinished }.count
                    Text(active > 0 ? String(localized: "\(active) 个进行中") : String(localized: "都已结束"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Every project with what it has cost, the ones under way first.
struct ProjectsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(AppSettings.baseCurrencyKey) private var baseCurrency = AppSettings.defaultBaseCurrency
    @Query(sort: \Project.createdAt, order: .reverse) private var queried: [Project]
    @State private var isNaming = false
    @State private var confirmDelete: Project?

    /// Every project, less one waiting to be deleted.
    private var projects: [Project] {
        queried.filter { !PendingDeletion.shared.hides($0) }
    }

    var body: some View {
        List {
            let active = projects.filter { !$0.isFinished }
            if !active.isEmpty {
                Section {
                    ForEach(active) { row($0) }
                }
            }
            let finished = projects.filter(\.isFinished)
            if !finished.isEmpty {
                Section("已结束") {
                    ForEach(finished) { row($0) }
                }
            }
        }
        .overlay {
            if projects.isEmpty {
                ContentUnavailableView {
                    Label("还没有项目", systemImage: "folder")
                } description: {
                    Text("装修、旅行这类跨好几个分类的开销，放进一个项目就能看出一共花了多少。记账时选一个项目，或者点右上角 + 新建。")
                }
            }
        }
        .deletionUndoBar()
        .deletionAlert(String(localized: "删除这个项目？"), item: $confirmDelete) { project in
            Button("删除", role: .destructive) {
                PendingDeletion.shared.delete([project], message: String(localized: "已删除「\(project.name)」"), in: context)
            }
        } message: { project in
            Text("「\(project.name)」\n账目和笔记都会保留，只是不再属于这个项目。")
        }
        .navigationTitle(Text(ScreenName.projects))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("新建项目", systemImage: "plus") { isNaming = true }
            }
        }
        .newProjectAlert(isPresented: $isNaming)
    }

    private func row(_ project: Project) -> some View {
        NavigationLink {
            ProjectDetailView(project: project)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .lineLimit(1)
                    Text(subtitle(project))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(project.spent.money(baseCurrency))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button(project.isFinished ? "恢复进行" : "结束项目", systemImage: project.isFinished ? "arrow.uturn.backward" : "checkmark") {
                withAnimation { project.isFinished.toggle() }
            }
            .tint(ModuleColor.money)
        }
        .swipeActions(allowsFullSwipe: false) {
            SwipeDeleteButton { confirmDelete = project }
        }
    }

    private func subtitle(_ project: Project) -> String {
        let entries = project.entries ?? []
        guard let last = entries.map(\.date).max() else { return String(localized: "还没有账目") }
        return String(localized: "\(entries.count) 笔 · 最近 \(DayText.dayWithWeekday(last))")
    }
}

/// One project: what it has cost, where that went, the notes that follow it, and every entry.
struct ProjectDetailView: View {
    let project: Project

    @Environment(AppRouter.self) private var router
    @AppStorage(AppSettings.baseCurrencyKey) private var baseCurrency = AppSettings.defaultBaseCurrency
    @State private var actions = EntryActions()
    @State private var isCreating = false
    @State private var isRenaming = false
    @State private var newName = ""

    /// Its entries, less one waiting to be deleted.
    private var entries: [LedgerEntry] {
        (project.entries ?? []).filter { !PendingDeletion.shared.hides($0) }
    }

    var body: some View {
        let expenses = entries.filter { $0.kind == .expense }
        let spent = expenses.reduce(Decimal(0)) { $0 + $1.baseAmount }
        let received = entries.filter { $0.kind == .income }.reduce(Decimal(0)) { $0 + $1.baseAmount }
        let totals = CategoryTotal.totals(of: expenses)
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("一共花了")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(spent.money(baseCurrency))
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                    Text(summaryLine(received: received))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            if !totals.isEmpty {
                Section("花在哪") {
                    ForEach(totals) { total in
                        CategoryTotalRow(total: total, kind: .expense, largest: totals.first?.amount ?? 0, sum: spent, baseCurrency: baseCurrency)
                    }
                }
            }

            let notes = project.notes ?? []
            if !notes.isEmpty {
                Section("笔记") {
                    ForEach(notes) { note in
                        Button {
                            router.open(note)
                        } label: {
                            Label(note.displayTitle, systemImage: "note.text")
                        }
                    }
                }
            }

            EntriesByDay(entries: entries, baseCurrency: baseCurrency, actions: $actions)
        }
        .deletionUndoBar()
        .entryActions($actions)
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("管理", systemImage: "ellipsis") {
                    Button("改名", systemImage: "pencil") {
                        newName = project.name
                        isRenaming = true
                    }
                    Button(project.isFinished ? "恢复进行" : "结束项目", systemImage: project.isFinished ? "arrow.uturn.backward" : "checkmark") {
                        project.isFinished.toggle()
                    }
                }
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button("记一笔", systemImage: "plus") { isCreating = true }
            }
        }
        .sheet(isPresented: $isCreating) {
            NavigationStack { EntryEditorView(entry: nil, project: project) }
        }
        .alert("项目名称", isPresented: $isRenaming) {
            TextField("如 装修、日本旅行", text: $newName)
            Button("取消", role: .cancel) {}
            Button("保存") {
                if !newName.trimmed.isEmpty { project.name = newName.trimmed }
            }
        }
    }

    private func summaryLine(received: Decimal) -> String {
        let dates = entries.map(\.date)
        var parts = [String(localized: "\(entries.count) 笔")]
        if let first = dates.min(), let last = dates.max() {
            let from = first.formatted(.dateTime.year().month().day())
            parts.append(Calendar.current.isDate(first, inSameDayAs: last) ? from : "\(from) – \(last.formatted(.dateTime.year().month().day()))")
        }
        if received > 0 { parts.append(String(localized: "收入 \(received.money(baseCurrency))")) }
        return parts.joined(separator: " · ")
    }
}

/// 「项目」 on an entry: picks one, or makes one on the spot. The caller hands in the list, so the
/// capture sheet's pages don't each query for it.
struct ProjectField: View {
    @Binding var selection: Project?
    let projects: [Project]

    @State private var isNaming = false

    var body: some View {
        LabeledContent("项目") {
            Menu {
                Button("不属于项目") { selection = nil }
                ForEach(projects) { project in
                    Button(project.name) { selection = project }
                }
                Divider()
                Button("新建项目…", systemImage: "plus") { isNaming = true }
            } label: {
                Text(selection?.name ?? String(localized: "无"))
                    .foregroundStyle(selection == nil ? Color.secondary : Color.primary)
            }
        }
        .newProjectAlert(isPresented: $isNaming) { selection = $0 }
    }
}

extension View {
    /// Asks for a name and makes the project, or finds the one already called that.
    func newProjectAlert(isPresented: Binding<Bool>, onCreate: @escaping (Project) -> Void = { _ in }) -> some View {
        modifier(NewProjectAlert(isPresented: isPresented, onCreate: onCreate))
    }
}

private struct NewProjectAlert: ViewModifier {
    @Binding var isPresented: Bool
    let onCreate: (Project) -> Void

    @Environment(\.modelContext) private var context
    @State private var name = ""

    func body(content: Content) -> some View {
        content.alert("新建项目", isPresented: $isPresented) {
            TextField("如 装修、日本旅行", text: $name)
            Button("取消", role: .cancel) { name = "" }
            Button("创建", action: create)
        } message: {
            Text("装修、旅行这类跨好几个分类的开销，放进一个项目就能看出一共花了多少。")
        }
    }

    private func create() {
        let wanted = name.trimmed
        name = ""
        guard !wanted.isEmpty else { return }
        let existing = (try? context.fetch(FetchDescriptor<Project>()))?.first { $0.name == wanted }
        let project = existing ?? Project(name: wanted)
        if existing == nil { context.insert(project) }
        project.isFinished = false
        onCreate(project)
    }
}

/// 「项目」 in a note's toolbar: which project the note follows.
struct NoteProjectMenu: View {
    @Bindable var note: Note
    @Binding var isNaming: Bool

    @Query(filter: #Predicate<Project> { !$0.isFinished }, sort: \Project.createdAt, order: .reverse) private var projects: [Project]

    var body: some View {
        Menu("关联项目", systemImage: note.project == nil ? "folder" : "folder.fill") {
            Button("不关联项目") { note.project = nil }
            ForEach(projects) { project in
                Button(project.name) { note.project = project }
            }
            Divider()
            Button("新建项目…", systemImage: "plus") { isNaming = true }
        }
    }
}
