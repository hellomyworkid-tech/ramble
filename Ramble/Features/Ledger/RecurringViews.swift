import SwiftData
import SwiftUI

/// Income and spending that comes round by itself: 工资, 房租, 订阅.
struct RecurringEntriesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \RecurringEntry.nextDate) private var queried: [RecurringEntry]
    @State private var isCreating = false
    @State private var editing: RecurringEntry?
    @State private var confirming: RecurringEntry?
    @State private var confirmDelete: RecurringEntry?

    /// Every rule, less one waiting to be deleted.
    private var rules: [RecurringEntry] {
        queried.filter { !PendingDeletion.shared.hides($0) }
    }

    var body: some View {
        List {
            let active = rules.filter(\.isActive)
            if !active.isEmpty {
                Section {
                    ForEach(active) { row($0) }
                } footer: {
                    Text("要到期提醒、付了才算的（信用卡、房租），放在「提醒 › 账单」更合适。")
                }
            }
            let finished = rules.filter { !$0.isActive }
            if !finished.isEmpty {
                Section("已结束") {
                    ForEach(finished) { row($0) }
                }
            }
        }
        .overlay {
            if rules.isEmpty {
                ContentUnavailableView {
                    Label("还没有定期记账", systemImage: "arrow.triangle.2.circlepath")
                } description: {
                    Text("工资、订阅这类每期都有的收支，设好之后到日子自动记一笔，也可以先问你一声。")
                }
            }
        }
        .deletionUndoBar()
        .deletionAlert(String(localized: "删除这条定期记账？"), item: $confirmDelete) { rule in
            Button("删除", role: .destructive) {
                PendingDeletion.shared.delete([rule], message: String(localized: "已删除「\(rule.name)」"), in: context)
            }
        } message: { rule in
            Text("「\(rule.name)」\n已记的账会保留。")
        }
        .navigationTitle(Text(ScreenName.recurring))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("新建定期记账", systemImage: "plus") { isCreating = true }
            }
        }
        .sheet(isPresented: $isCreating) {
            NavigationStack { RecurringEditorView(rule: nil) }
        }
        .sheet(item: $editing) { rule in
            NavigationStack { RecurringEditorView(rule: rule) }
        }
        .sheet(item: $confirming) { rule in
            NavigationStack { RecurringConfirmView(rule: rule) }
                .presentationDetents([.medium, .large])
        }
    }

    private func row(_ rule: RecurringEntry) -> some View {
        RecurringRow(rule: rule)
            .contentShape(.rect)
            .onTapGesture {
                if rule.asksFirst, rule.isDue() { confirming = rule } else { editing = rule }
            }
            .swipeActions(allowsFullSwipe: false) {
                SwipeDeleteButton { confirmDelete = rule }
            }
    }
}

struct RecurringRow: View {
    let rule: RecurringEntry

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: rule.category?.symbol ?? "arrow.triangle.2.circlepath",
                     color: rule.isActive ? Color(hex: rule.category?.colorHex ?? "#6E6E73") : ModuleColor.neutral)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(rule.asksFirst && rule.isDue() ? ModuleColor.warning : .secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text((rule.kind == .income ? "+" : "−") + rule.amount.money(rule.currencyCode))
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(rule.kind == .income ? ModuleColor.money : Color.primary)
        }
    }

    private var subtitle: String {
        guard rule.isActive else { return String(localized: "已结束") }
        let when = rule.nextDate.formatted(.dateTime.month().day())
        if rule.asksFirst, rule.isDue() { return String(localized: "\(when)，点一下确认") }
        let repeats = rule.recurrence?.summary(anchor: rule.nextDate) ?? String(localized: "一次性")
        return String(localized: "\(repeats) · 下次 \(when)") + (rule.asksFirst ? String(localized: " · 先问我") : "")
    }
}

/// Adds or edits one rule.
struct RecurringEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let rule: RecurringEntry?

    @Query(filter: #Predicate<Account> { !$0.isArchived }, sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]

    @State private var kind: EntryKind
    @State private var name: String
    @State private var amountText: String
    @State private var currencyCode: String
    @State private var date: Date
    @State private var recurrence: Recurrence?
    @State private var asksFirst: Bool
    @State private var category: LedgerCategory?
    @State private var account: Account?
    @FocusState private var amountFocused: Bool

    init(rule: RecurringEntry?) {
        self.rule = rule
        let base = UserDefaults.standard.string(forKey: AppSettings.baseCurrencyKey) ?? AppSettings.defaultBaseCurrency
        // A month from now, as it repeats monthly until told otherwise: today's has often been recorded already.
        let start = rule?.nextDate ?? Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now
        _kind = State(initialValue: rule?.kind ?? .income)
        _name = State(initialValue: rule?.name ?? "")
        _amountText = State(initialValue: rule?.amount.inputText ?? "")
        _currencyCode = State(initialValue: rule?.currencyCode ?? base)
        _date = State(initialValue: start)
        _recurrence = State(initialValue: rule == nil ? Recurrence.monthly().normalized(anchor: start) : rule?.recurrence)
        _asksFirst = State(initialValue: rule?.asksFirst ?? false)
        _category = State(initialValue: rule?.category)
        _account = State(initialValue: rule?.account)
    }

    var body: some View {
        Form {
            Section {
                Picker("类型", selection: $kind) {
                    Text(EntryKind.income.title).tag(EntryKind.income)
                    Text(EntryKind.expense.title).tag(EntryKind.expense)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                TextField("名称（如 工资、视频会员）", text: $name)
                    .font(.headline)
                AmountField(text: $amountText, currencyCode: currencyCode, focused: $amountFocused)
                CurrencyPicker(title: "币种", code: $currencyCode)
            }

            Section {
                // Not earlier than today: a date in the past would fill in every occurrence since.
                DatePicker("下一次", selection: $date, in: earliest..., displayedComponents: .date)
                RecurrenceField(recurrence: $recurrence, anchor: date)
                Toggle("到日子先问我", isOn: $asksFirst)
            } footer: {
                Text(asksFirst
                     ? "到日子时提醒你，在「今天」页确认金额后才记一笔，适合金额不固定的。"
                     : "到日子自动记一笔，不用确认。没打开 App 的日子，下次打开时补上。")
            }

            Section {
                CategoryField(title: "分类", kind: kind.categoryKind ?? .expense,
                              categories: categories.filter { $0.kind == kind.categoryKind }, selection: $category)
                Picker("账户", selection: $account) {
                    Text("不指定").tag(Account?.none)
                    ForEach(accounts) { Text($0.name).tag(Optional($0)) }
                }
            }
        }
        .navigationTitle(rule == nil ? "新建定期记账" : "编辑定期记账")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消", systemImage: "xmark", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", systemImage: "checkmark", role: .confirm, action: save)
                    .disabled(name.trimmed.isEmpty || amount == nil)
            }
        }
        .onChange(of: kind) { _, newKind in
            if category?.kind != newKind.categoryKind { category = nil }
        }
        .onChange(of: date) { _, day in recurrence = recurrence?.following(day) }
        .onAppear { if rule == nil { amountFocused = true } }
    }

    private var earliest: Date {
        min(Calendar.current.startOfDay(for: rule?.nextDate ?? .now), Calendar.current.startOfDay(for: .now))
    }

    private var amount: Decimal? {
        guard let value = Decimal(userInput: amountText), value > 0 else { return nil }
        return value
    }

    private func save() {
        guard let amount else { return }
        let day = RecurringEntry.occurrence(on: date)
        let target = rule ?? RecurringEntry(kind: kind, name: name.trimmed, amount: amount, nextDate: day, recurrence: nil)
        if rule == nil { context.insert(target) }
        target.kind = kind
        target.name = name.trimmed
        target.amount = amount
        target.currencyCode = currencyCode
        target.nextDate = day
        target.recurrence = recurrence?.normalized(anchor: day)
        target.asksFirst = asksFirst
        target.isActive = true
        target.category = category
        target.account = account
        // Today's, if that's the day picked.
        RecurringEntries.recordDue(in: context)
        dismiss()
    }
}

/// A rule that asked first, on its day: the amount it really came to, or skip it this time.
struct RecurringConfirmView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let rule: RecurringEntry

    @Query(filter: #Predicate<Account> { !$0.isArchived }, sort: \Account.sortOrder) private var accounts: [Account]
    @State private var amountText: String
    @State private var account: Account?
    @FocusState private var amountFocused: Bool

    init(rule: RecurringEntry) {
        self.rule = rule
        _amountText = State(initialValue: rule.amount.inputText)
        _account = State(initialValue: rule.account)
    }

    var body: some View {
        Form {
            Section {
                AmountField(text: $amountText, currencyCode: rule.currencyCode, focused: $amountFocused)
            } header: {
                Text(rule.kind == .income ? "这次收到" : "这次付出")
            }
            Section {
                Picker("账户", selection: $account) {
                    Text("不指定").tag(Account?.none)
                    ForEach(accounts) { Text($0.name).tag(Optional($0)) }
                }
                LabeledContent("日期", value: DayText.dayWithWeekday(rule.nextDate))
            } footer: {
                Text(nextText)
            }
            Section {
                Button("跳过这次") {
                    rule.skip()
                    dismiss()
                }
            }
        }
        .navigationTitle(rule.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消", systemImage: "xmark", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("记一笔", systemImage: "checkmark", role: .confirm) {
                    guard let amount else { return }
                    rule.record(amount: amount, account: account, in: context)
                    dismiss()
                }
                .disabled(amount == nil)
            }
        }
    }

    private var amount: Decimal? {
        guard let value = Decimal(userInput: amountText), value > 0 else { return nil }
        return value
    }

    private var nextText: String {
        if let next = rule.recurrence?.nextOccurrence(after: rule.nextDate) {
            return String(localized: "下一次：\(DayText.dayWithWeekday(next))")
        }
        return String(localized: "这是最后一次。")
    }
}
