import SwiftData
import SwiftUI

struct BillEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let bill: Bill?
    var onFinish: (() -> Void)?

    @Query(filter: #Predicate<Account> { !$0.isArchived }, sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]

    @State private var name: String
    @State private var kind: BillKind
    @State private var amountText: String
    @State private var isEstimated: Bool
    @State private var currencyCode: String
    @State private var dueDate: Date
    @State private var recurrence: Recurrence?
    @State private var reminderRules: [ReminderRule]
    @State private var account: Account?
    @State private var creditAccount: Account?
    @State private var category: LedgerCategory?
    @State private var autoRecord: Bool
    @State private var note: String
    @State private var confirmDelete = false
    @State private var isPaying = false
    @State private var didPay = false
    @FocusState private var amountFocused: Bool

    init(bill: Bill?, onFinish: (() -> Void)? = nil) {
        self.bill = bill
        self.onFinish = onFinish
        let base = UserDefaults.standard.string(forKey: AppSettings.baseCurrencyKey) ?? AppSettings.defaultBaseCurrency
        let defaultDue = Calendar.current.startOfDay(for: .now)
        _name = State(initialValue: bill?.name ?? "")
        _kind = State(initialValue: bill?.kind ?? .creditCard)
        _amountText = State(initialValue: bill?.amount.inputText ?? "")
        _isEstimated = State(initialValue: bill?.isAmountEstimated ?? false)
        _currencyCode = State(initialValue: bill?.currencyCode ?? base)
        _dueDate = State(initialValue: bill?.nextDueDate ?? defaultDue)
        _recurrence = State(initialValue: bill == nil ? Recurrence.monthly().normalized(anchor: defaultDue) : bill?.recurrence)
        _reminderRules = State(initialValue: bill?.reminderRules ?? [ReminderRule(daysBefore: 3), ReminderRule(daysBefore: 0)])
        _account = State(initialValue: bill?.account)
        _creditAccount = State(initialValue: bill?.creditAccount)
        _category = State(initialValue: bill?.category)
        _autoRecord = State(initialValue: bill?.autoRecord ?? true)
        _note = State(initialValue: bill?.note ?? "")
    }

    var body: some View {
        Form {
            if let bill, bill.isActive {
                Section {
                    Button("标记这期已支付", systemImage: "checkmark.circle.fill") { isPaying = true }
                        .font(.headline)
                }
            }

            Section {
                TextField("名称（如 信用卡还款）", text: $name)
                    .font(.headline)
                Picker("类型", selection: $kind) {
                    ForEach(BillKind.allCases) { kind in
                        Label { Text(kind.title) } icon: { Image(systemName: kind.symbol) }.tag(kind)
                    }
                }
            }

            Section {
                AmountField(text: $amountText, currencyCode: currencyCode, focused: $amountFocused)
                Toggle("金额每期不固定", isOn: $isEstimated)
                CurrencyPicker(title: "币种", code: $currencyCode)
            } footer: {
                if isEstimated {
                    Text("提醒里会显示「约」，支付时再填实际金额。")
                }
            }

            Section {
                DatePicker("下次到期", selection: $dueDate, displayedComponents: .date)
                RecurrenceField(recurrence: $recurrence, anchor: dueDate)
                ReminderRulesField(rules: $reminderRules)
            }

            Section {
                Picker("付款账户", selection: $account) {
                    Text("不指定").tag(Account?.none)
                    ForEach(accounts) { Text($0.name).tag(Optional($0)) }
                }
                if kind == .creditCard {
                    Picker("还哪张卡", selection: $creditAccount) {
                        Text("不指定").tag(Account?.none)
                        ForEach(accounts.filter { $0.kind == .creditCard }) { Text($0.name).tag(Optional($0)) }
                    }
                    Toggle("支付后自动记一笔还款", isOn: $autoRecord)
                } else {
                    Picker("记账分类", selection: $category) {
                        Text("不指定").tag(LedgerCategory?.none)
                        ForEach(categories.filter { $0.kind == .expense }) { Text($0.name).tag(Optional($0)) }
                    }
                    Toggle("支付后自动记一笔支出", isOn: $autoRecord)
                }
            } footer: {
                if kind == .creditCard {
                    Text("还款记为从付款账户到信用卡的转账。刷卡消费已经算过支出，不会重复计算。")
                }
            }

            Section {
                TextField("备注", text: $note, axis: .vertical)
            }

            if bill != nil {
                Section {
                    Button("删除账单", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(bill == nil ? "新建账单" : "编辑账单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if onFinish == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", systemImage: "xmark", role: .cancel) { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", systemImage: "checkmark", role: .confirm, action: save)
                    .disabled(name.trimmed.isEmpty || Decimal(userInput: amountText) == nil)
            }
        }
        .confirmationDialog("删除这个账单？已记的账会保留。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let bill { context.delete(bill) }
                finish()
            }
        }
        // Paying rolls the due date forward; close the editor afterwards so its
        // stale draft can't be saved back over the new date.
        .sheet(isPresented: $isPaying, onDismiss: { if didPay { finish() } }) {
            if let bill {
                NavigationStack { MarkPaidView(bill: bill) { didPay = true } }
                    .presentationDetents([.medium, .large])
            }
        }
        .onChange(of: kind) { _, newKind in
            if bill == nil, name.trimmed.isEmpty || BillKind.allCases.contains(where: { String(localized: $0.title) == name }) {
                name = String(localized: newKind.title)
            }
            if newKind == .creditCard, creditAccount == nil {
                creditAccount = accounts.first { $0.kind == .creditCard }
            }
        }
        .onAppear {
            if bill == nil, kind == .creditCard, creditAccount == nil {
                creditAccount = accounts.first { $0.kind == .creditCard }
            }
        }
    }

    private func save() {
        guard let amount = Decimal(userInput: amountText) else { return }
        let target = bill ?? Bill(name: name.trimmed, kind: kind, amount: amount, nextDueDate: dueDate)
        if bill == nil { context.insert(target) }
        target.name = name.trimmed
        target.kind = kind
        target.amount = amount
        target.isAmountEstimated = isEstimated
        target.currencyCode = currencyCode
        target.nextDueDate = Calendar.current.startOfDay(for: dueDate)
        target.recurrence = recurrence?.normalized(anchor: dueDate)
        target.reminderRules = reminderRules
        target.account = account
        target.creditAccount = kind == .creditCard ? creditAccount : nil
        target.category = kind == .creditCard ? nil : category
        target.autoRecord = autoRecord
        target.note = note.trimmed
        target.isActive = true
        finish()
    }

    private func finish() {
        if let onFinish { onFinish() } else { dismiss() }
    }
}

/// "已支付" flow: confirm the real amount, record the expense, roll to the next period.
struct MarkPaidView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let bill: Bill
    var onPaid: (() -> Void)?

    @Query(filter: #Predicate<Account> { !$0.isArchived }, sort: \Account.sortOrder) private var accounts: [Account]
    @State private var amountText: String
    @State private var account: Account?
    @State private var date = Date.now
    @State private var recordEntry: Bool
    @FocusState private var amountFocused: Bool

    init(bill: Bill, onPaid: (() -> Void)? = nil) {
        self.bill = bill
        self.onPaid = onPaid
        _amountText = State(initialValue: bill.amount.inputText)
        _account = State(initialValue: bill.account)
        _recordEntry = State(initialValue: bill.autoRecord)
    }

    var body: some View {
        Form {
            Section {
                AmountField(text: $amountText, currencyCode: bill.currencyCode, focused: $amountFocused)
            } header: {
                Text(bill.isAmountEstimated ? "实际支付金额" : "支付金额")
            }

            Section {
                Picker("付款账户", selection: $account) {
                    Text("不指定").tag(Account?.none)
                    ForEach(accounts) { Text($0.name).tag(Optional($0)) }
                }
                DatePicker("支付日期", selection: $date, displayedComponents: .date)
                Toggle(bill.recordsAsTransfer ? "同时记一笔还款（转账）" : "同时记一笔支出", isOn: $recordEntry)
            } footer: {
                Text(nextPeriodText)
            }
        }
        .navigationTitle(bill.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消", systemImage: "xmark", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("确认已付", systemImage: "checkmark", role: .confirm) {
                    guard let amount = Decimal(userInput: amountText) else { return }
                    bill.markPaid(amount: amount, on: date, from: account, recordEntry: recordEntry, in: context)
                    onPaid?()
                    dismiss()
                }
                .disabled(Decimal(userInput: amountText) == nil)
            }
        }
        .onAppear { amountFocused = bill.isAmountEstimated }
    }

    private var nextPeriodText: String {
        if let next = bill.recurrence?.nextOccurrence(after: bill.nextDueDate) {
            return String(localized: "确认后提醒会移到下一期：\(DayText.dayWithWeekday(next))")
        }
        return String(localized: "这是一次性账单，确认后会移到「已结束」。")
    }
}
