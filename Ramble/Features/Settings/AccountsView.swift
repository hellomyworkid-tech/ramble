import SwiftData
import SwiftUI

struct AccountsView: View {
    @AppStorage(AppSettings.baseCurrencyKey) private var baseCurrency = AppSettings.defaultBaseCurrency
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @State private var editingAccount: Account?
    @State private var isCreating = false

    var body: some View {
        List {
            Section {
                ForEach(active) { account in
                    AccountRow(account: account)
                        .contentShape(.rect)
                        .onTapGesture { editingAccount = account }
                }
                .onMove(perform: move)
            } footer: {
                if !netWorthIsMixed {
                    Text("净资产 \(netWorth.money(baseCurrency))")
                }
            }

            let archived = accounts.filter(\.isArchived)
            if !archived.isEmpty {
                Section("已归档") {
                    ForEach(archived) { account in
                        AccountRow(account: account)
                            .contentShape(.rect)
                            .onTapGesture { editingAccount = account }
                    }
                }
            }
        }
        .navigationTitle(Text(ScreenName.accounts))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button("新建账户", systemImage: "plus") { isCreating = true }
            }
        }
        .sheet(isPresented: $isCreating) {
            NavigationStack { AccountEditorView(account: nil, nextSortOrder: (accounts.map(\.sortOrder).max() ?? -1) + 1) }
        }
        .sheet(item: $editingAccount) { account in
            NavigationStack { AccountEditorView(account: account, nextSortOrder: account.sortOrder) }
        }
    }

    private var active: [Account] {
        accounts.filter { !$0.isArchived }
    }

    private var netWorthIsMixed: Bool {
        active.contains { $0.currencyCode != baseCurrency }
    }

    private var netWorth: Decimal {
        active.reduce(0) { $0 + $1.balance }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ordered = active
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, account) in ordered.enumerated() {
            account.sortOrder = index
        }
    }
}

private struct AccountRow: View {
    let account: Account

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: account.kind.symbol, color: account.kind == .creditCard ? ModuleColor.bills : ModuleColor.money)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                Text(account.kind.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(account.balance.money(account.currencyCode))
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(account.balance < 0 ? Color.red : Color.primary)
        }
    }
}

struct AccountEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let account: Account?
    let nextSortOrder: Int

    @State private var name: String
    @State private var kind: AccountKind
    @State private var currencyCode: String
    @State private var initialBalanceText: String
    @State private var creditLimitText: String
    @State private var statementDay: Int
    @State private var paymentDueDay: Int
    @State private var isArchived: Bool
    @State private var confirmDelete = false

    init(account: Account?, nextSortOrder: Int) {
        self.account = account
        self.nextSortOrder = nextSortOrder
        let base = UserDefaults.standard.string(forKey: AppSettings.baseCurrencyKey) ?? AppSettings.defaultBaseCurrency
        _name = State(initialValue: account?.name ?? "")
        _kind = State(initialValue: account?.kind ?? .debitCard)
        _currencyCode = State(initialValue: account?.currencyCode ?? base)
        _initialBalanceText = State(initialValue: account.map { $0.initialBalance == 0 ? "" : $0.initialBalance.inputText } ?? "")
        _creditLimitText = State(initialValue: account?.creditLimit?.inputText ?? "")
        _statementDay = State(initialValue: account?.statementDay ?? 0)
        _paymentDueDay = State(initialValue: account?.paymentDueDay ?? 0)
        _isArchived = State(initialValue: account?.isArchived ?? false)
    }

    var body: some View {
        Form {
            Section {
                TextField("名称（如 招行储蓄卡）", text: $name)
                Picker("类型", selection: $kind) {
                    ForEach(AccountKind.allCases) { kind in
                        Label { Text(kind.title) } icon: { Image(systemName: kind.symbol) }.tag(kind)
                    }
                }
                CurrencyPicker(title: "币种", code: $currencyCode)
            }

            Section {
                LabeledContent("初始余额") {
                    TextField("0", text: $initialBalanceText)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                }
            } footer: {
                Text(kind == .creditCard ? "信用卡已欠款请填负数，如 -2000。" : "开始记账时账户里的钱。")
            }

            if kind == .creditCard {
                Section("信用卡") {
                    LabeledContent("额度") {
                        TextField("可不填", text: $creditLimitText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    dayPicker("账单日", selection: $statementDay)
                    dayPicker("还款日", selection: $paymentDueDay)
                }
            }

            if account != nil {
                Section {
                    Toggle("归档（不再出现在记账选项里）", isOn: $isArchived)
                    Button("删除账户", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(account == nil ? "新建账户" : "编辑账户")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消", systemImage: "xmark", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", systemImage: "checkmark", role: .confirm, action: save)
                    .disabled(name.trimmed.isEmpty)
            }
        }
        .confirmationDialog("删除账户？相关的记账会保留，但不再关联这个账户。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let account { context.delete(account) }
                dismiss()
            }
        }
    }

    private func dayPicker(_ title: LocalizedStringResource, selection: Binding<Int>) -> some View {
        Picker(selection: selection) {
            Text("不设置").tag(0)
            ForEach(1...28, id: \.self) { day in
                Text("每月 \(day) 日").tag(day)
            }
        } label: {
            Text(title)
        }
    }

    private func save() {
        let target = account ?? Account(name: name.trimmed, kind: kind, currencyCode: currencyCode, sortOrder: nextSortOrder)
        if account == nil { context.insert(target) }
        target.name = name.trimmed
        target.kind = kind
        target.currencyCode = currencyCode
        target.initialBalance = Decimal(userInput: initialBalanceText) ?? 0
        if kind == .creditCard {
            target.creditLimit = Decimal(userInput: creditLimitText)
            target.statementDay = statementDay == 0 ? nil : statementDay
            target.paymentDueDay = paymentDueDay == 0 ? nil : paymentDueDay
        } else {
            target.creditLimit = nil
            target.statementDay = nil
            target.paymentDueDay = nil
        }
        target.isArchived = isArchived
        dismiss()
    }
}
