import SwiftUI

/// Edits one AI draft before it is saved. Changing a field clears its "待确认" tag.
struct DraftEditorView: View {
    @Binding var draft: CaptureDraft
    let categories: [LedgerCategory]
    let accounts: [Account]
    var notes: [Note] = []

    @FocusState private var amountFocused: Bool

    var body: some View {
        Form {
            Section {
                Picker("类型", selection: $draft.kind) {
                    ForEach(DraftKind.allCases) { Text($0.title).tag($0) }
                }
                TextField("名称", text: $draft.title)
            }

            if draft.kind.hasAmount {
                Section {
                    AmountField(text: $draft.amountText, currencyCode: draft.currencyCode, focused: $amountFocused)
                    if draft.kind == .bill {
                        Toggle("金额每期不固定", isOn: $draft.amountIsApproximate)
                    }
                    CurrencyPicker(title: "币种", code: $draft.currencyCode)
                }
            }

            switch draft.kind {
            case .expense, .income:
                Section {
                    categoryPicker
                    accountPicker("账户", selection: $draft.account)
                    DatePicker("时间", selection: dateBinding)
                }
            case .transfer:
                Section {
                    accountPicker("转出账户", selection: $draft.account)
                    accountPicker("转入账户", selection: $draft.toAccount)
                    DatePicker("时间", selection: dateBinding)
                }
            case .task:
                Section {
                    Toggle("日期", isOn: hasDateBinding.animation())
                    if draft.date != nil {
                        DatePicker("日期", selection: dateBinding, displayedComponents: .date)
                        Toggle("时间", isOn: $draft.hasTime.animation())
                        if draft.hasTime {
                            DatePicker("时间", selection: dateBinding, displayedComponents: .hourAndMinute)
                        }
                        RecurrenceField(recurrence: $draft.recurrence, anchor: dateBinding.wrappedValue)
                    }
                }
                Section {
                    Picker("优先级", selection: $draft.priority) {
                        ForEach(TaskPriority.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledContent("清单") {
                        TextField("如 工作、家庭", text: $draft.listName)
                            .multilineTextAlignment(.trailing)
                    }
                }
            case .bill:
                Section {
                    Picker("账单类型", selection: $draft.billKind) {
                        ForEach(BillKind.allCases) { Text($0.title).tag($0) }
                    }
                    DatePicker("下次到期", selection: dateBinding, displayedComponents: .date)
                    RecurrenceField(recurrence: $draft.recurrence, anchor: dateBinding.wrappedValue)
                    ReminderRulesField(rules: $draft.reminderRules)
                }
                Section {
                    accountPicker("付款账户", selection: $draft.account)
                    if draft.billKind == .creditCard {
                        accountPicker("还哪张卡", selection: $draft.toAccount, kinds: [.creditCard])
                    } else {
                        categoryPicker
                    }
                }
            case .note:
                if draft.appendsToEntry == nil {
                    Section {
                        Picker("放进", selection: noteTargetBinding) {
                            Text("新建笔记").tag(Note?.none)
                            ForEach(notes) { Text($0.displayTitle).tag(Optional($0)) }
                        }
                        if !(draft.updatesExisting && draft.existingNote != nil) {
                            TextField("新笔记名称", text: $draft.title)
                        }
                    }
                }
                Section("内容") {
                    TextField("内容", text: $draft.note, axis: .vertical)
                        .lineLimit(4...16)
                    Toggle(isOn: $draft.isKeyPoint) {
                        Label("标为重点", systemImage: draft.isKeyPoint ? "star.fill" : "star")
                            .foregroundStyle(draft.isKeyPoint ? ModuleColor.keyPoint : .primary)
                    }
                }
            case .receivable, .payable:
                Section {
                    LabeledContent(draft.kind == .receivable ? "谁欠我" : "欠谁") {
                        TextField("如 张三、装修师傅", text: $draft.counterparty)
                            .multilineTextAlignment(.trailing)
                    }
                    Toggle(draft.kind == .receivable ? "预计收到日期" : "约定付款日期", isOn: hasDateBinding.animation())
                    if draft.date != nil {
                        DatePicker("日期", selection: dateBinding, displayedComponents: .date)
                    }
                } footer: {
                    Text(draft.kind == .receivable
                         ? "先记在「账本 › 应收应付」，不算进收入。收到钱时点「收到了」，再记成收入。"
                         : "先记在「账本 › 应收应付」，不算进支出。付钱时点「付了」，再记成支出。")
                }
                Section {
                    categoryPicker
                    accountPicker(draft.kind == .receivable ? "收款账户" : "付款账户", selection: $draft.account)
                }
            case .expiry:
                Section {
                    Picker("类型", selection: $draft.expiryKind) {
                        ForEach(ExpiryKind.allCases) { Text($0.title).tag($0) }
                    }
                    DatePicker("到期日", selection: dateBinding, displayedComponents: .date)
                    Toggle("只确定到月份", isOn: $draft.dateIsApproximate)
                    ReminderRulesField(rules: $draft.reminderRules)
                }
            }

            if draft.kind != .note {
                Section {
                    TextField("备注", text: $draft.note, axis: .vertical)
                }
            }
        }
        .navigationTitle("修改这条")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: draft.title) { draft.uncertain.remove("title") }
        .onChange(of: draft.amountText) { draft.uncertain.remove("amount") }
        .onChange(of: draft.amountIsApproximate) { _, approximate in
            if !approximate { draft.uncertain.remove("amount") }
        }
        .onChange(of: draft.category) { draft.uncertain.remove("category") }
        .onChange(of: draft.account) { draft.uncertain.remove("account") }
        .onChange(of: draft.dateIsApproximate) { _, approximate in
            if !approximate { draft.uncertain.remove("date") }
        }
        .onChange(of: draft.kind) { _, kind in
            let wanted: CategoryKind = kind == .income || kind == .receivable ? .income : .expense
            if draft.category?.kind != wanted { draft.category = nil }
            // Records with money or a due date need a date; owed money only when it's known.
            if ![.task, .note, .receivable, .payable].contains(kind), draft.date == nil {
                draft.date = Calendar.current.startOfDay(for: .now)
            }
        }
    }

    private var categoryPicker: some View {
        let wanted: CategoryKind = draft.kind == .income || draft.kind == .receivable ? .income : .expense
        return Picker("分类", selection: $draft.category) {
            Text("未分类").tag(LedgerCategory?.none)
            ForEach(categories.filter { $0.kind == wanted }) { Text($0.name).tag(Optional($0)) }
        }
    }

    private func accountPicker(_ title: LocalizedStringResource, selection: Binding<Account?>, kinds: [AccountKind]? = nil) -> some View {
        Picker(selection: selection) {
            Text("不指定").tag(Account?.none)
            ForEach(accounts.filter { !$0.isArchived && (kinds?.contains($0.kind) ?? true) }) {
                Text($0.name).tag(Optional($0))
            }
        } label: {
            Text(title)
        }
    }

    /// nil = a new note.
    private var noteTargetBinding: Binding<Note?> {
        Binding(
            get: { draft.updatesExisting ? draft.existingNote : nil },
            set: { note in
                draft.existingNote = note ?? draft.existingNote
                draft.updatesExisting = note != nil
            }
        )
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { draft.date ?? .now },
            set: { newValue in
                draft.date = newValue
                draft.uncertain.remove("date")
            }
        )
    }

    private var hasDateBinding: Binding<Bool> {
        Binding(
            get: { draft.date != nil },
            set: { on in draft.date = on ? Calendar.current.startOfDay(for: .now) : nil }
        )
    }
}
