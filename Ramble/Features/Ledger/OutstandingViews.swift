import SwiftData
import SwiftUI

/// The 应收应付 line under the month's figures: what's still owed each way, in the base currency.
struct OutstandingSummaryRow: View {
    let baseCurrency: String
    @Query private var items: [Outstanding]

    var body: some View {
        let open = items.filter { !$0.isSettled }
        let receivable = open.filter { $0.direction == .receivable }
        let payable = open.filter { $0.direction == .payable }
        NavigationLink {
            OutstandingListView()
        } label: {
            HStack(spacing: 12) {
                IconTile(symbol: "arrow.left.arrow.right", color: ModuleColor.money)
                Text("应收应付")
                Spacer(minLength: 8)
                if open.isEmpty {
                    Text("暂无")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        if !receivable.isEmpty {
                            Text("应收 \(Outstanding.total(receivable, base: baseCurrency).money(baseCurrency))")
                        }
                        if !payable.isEmpty {
                            Text("应付 \(Outstanding.total(payable, base: baseCurrency).money(baseCurrency))")
                        }
                    }
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

extension Outstanding {
    /// What's still owed, in the base currency at today's rates.
    static func total(_ items: [Outstanding], base: String) -> Decimal {
        items.reduce(0) { sum, item in
            let rate = item.currencyCode == base ? 1 : (ExchangeRates.shared.rateToBase(item.currencyCode, base: base) ?? 1)
            return sum + item.remaining * rate
        }
    }
}

/// Everything owed either way. One tap on 「收到了」 or 「付了」 records the rest as income or
/// expense today; a part payment goes through the row's menu.
struct OutstandingListView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(AppSettings.baseCurrencyKey) private var baseCurrency = AppSettings.defaultBaseCurrency
    @Query(sort: \Outstanding.createdAt, order: .reverse) private var items: [Outstanding]
    @State private var creating: OutstandingDirection?
    @State private var editing: Outstanding?
    @State private var partlySettling: Outstanding?
    @State private var pendingDelete: Outstanding?
    @State private var justSettled: JustSettled?

    /// The entry a tap just recorded, so it can be undone.
    private struct JustSettled: Equatable {
        let entry: LedgerEntry
        let text: String
    }

    var body: some View {
        List {
            ForEach(OutstandingDirection.allCases) { direction in
                let open = items.filter { $0.direction == direction && !$0.isSettled }.sorted { Self.dueFirst($0, $1) }
                Section {
                    if open.isEmpty {
                        Text(direction == .receivable ? "没有别人欠你的钱" : "没有你欠别人的钱")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(open) { item in
                        openRow(item)
                    }
                } header: {
                    HStack {
                        Text(direction == .receivable ? "应收 · 别人欠我" : "应付 · 我欠别人")
                        Spacer()
                        if !open.isEmpty {
                            Text(Outstanding.total(open, base: baseCurrency).money(baseCurrency))
                                .monospacedDigit()
                        }
                    }
                }
            }

            let settled = items.filter(\.isSettled).sorted { ($0.settledAt ?? $0.createdAt) > ($1.settledAt ?? $1.createdAt) }
            if !settled.isEmpty {
                Section("已结清") {
                    ForEach(settled) { item in
                        settledRow(item)
                    }
                }
            }
        }
        .navigationTitle("应收应付")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("新建", systemImage: "plus") {
                    Button("应收（别人欠我）", systemImage: "arrow.down.left") { creating = .receivable }
                    Button("应付（我欠别人）", systemImage: "arrow.up.right") { creating = .payable }
                }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("没有应收应付", systemImage: "arrow.left.arrow.right")
                } description: {
                    Text("别人欠你的、你欠别人的钱先记在这里，不算进收支。收到或付出时点一下，就记成一笔收入或支出。\n也可以直接说「张三还欠我两千」「还欠装修师傅三千工钱」。")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let justSettled {
                undoBanner(justSettled)
            }
        }
        .animation(.default, value: justSettled)
        .sheet(item: $creating) { direction in
            NavigationStack { OutstandingEditorView(item: nil, direction: direction) }
        }
        .sheet(item: $editing) { item in
            NavigationStack { OutstandingEditorView(item: item, direction: item.direction) }
        }
        .sheet(item: $partlySettling) { item in
            NavigationStack { SettleOutstandingView(item: item) }
        }
        .deletionAlert(pendingDelete.map { String(localized: "删除「\($0.displayTitle)」？") } ?? "", item: $pendingDelete) { item in
            Button("删除", role: .destructive) { context.delete(item) }
        } message: { item in
            Text((item.settlements ?? []).isEmpty ? "删除后不会留下记录。" : "已经记进账本的收入或支出不会删除。")
        }
    }

    private func openRow(_ item: Outstanding) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayTitle)
                    .lineLimit(1)
                Text(subtitle(item))
                    .font(.footnote)
                    .foregroundStyle(item.isOverdue() ? ModuleColor.warning : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.remaining.money(item.currencyCode))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                if item.settledAmount > 0 {
                    Text("共 \(item.amount.money(item.currencyCode))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button(String(localized: item.direction.settleTitle)) { settleRest(of: item) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(item.direction == .receivable ? ModuleColor.money : .accentColor)
        }
        .contentShape(.rect)
        .onTapGesture { editing = item }
        .contextMenu {
            Button(item.direction == .receivable ? "收到一部分…" : "付了一部分…", systemImage: "circle.lefthalf.filled") {
                partlySettling = item
            }
            Button("修改", systemImage: "pencil") { editing = item }
            Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = item }
        }
        .swipeActions {
            Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = item }
            Button("部分", systemImage: "circle.lefthalf.filled") { partlySettling = item }
                .tint(.orange)
        }
    }

    private func settledRow(_ item: Outstanding) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .lineLimit(1)
                Text("\(String(localized: item.direction.title)) · \(item.settledAt.map(DayText.dayWithWeekday) ?? "") 结清")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(item.amount.money(item.currencyCode))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .onTapGesture { editing = item }
        .swipeActions {
            Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = item }
        }
    }

    private func subtitle(_ item: Outstanding) -> String {
        var parts: [String] = []
        if let due = item.dueDate {
            parts.append(item.isOverdue()
                         ? String(localized: "已过 \(DayText.dayWithWeekday(due))")
                         : String(localized: "预计 \(DayText.dayWithWeekday(due))"))
        }
        if item.settledAmount > 0 {
            let done = item.settledAmount.money(item.currencyCode)
            parts.append(item.direction == .receivable ? String(localized: "已收 \(done)") : String(localized: "已付 \(done)"))
        }
        if let category = item.category { parts.append(category.name) }
        if parts.isEmpty { parts.append(String(localized: "记于 \(DayText.dayWithWeekday(item.createdAt))")) }
        return parts.joined(separator: " · ")
    }

    /// Records whatever's left, today, into the item's account and category.
    private func settleRest(of item: Outstanding) {
        let amount = item.remaining
        guard amount > 0 else { return }
        let entry = item.settle(amount: amount, on: .now, account: nil, in: context)
        let kind = item.direction == .receivable ? String(localized: "收入") : String(localized: "支出")
        justSettled = JustSettled(entry: entry, text: String(localized: "已记一笔\(kind) \(amount.money(item.currencyCode))"))
        let shown = justSettled
        Task {
            try? await Task.sleep(for: .seconds(5))
            if justSettled == shown { justSettled = nil }
        }
    }

    private func undoBanner(_ settled: JustSettled) -> some View {
        HStack {
            Label(settled.text, systemImage: "checkmark.circle.fill")
                .font(.subheadline)
            Spacer()
            Button("撤销") {
                context.delete(settled.entry)
                justSettled = nil
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Overdue and soonest first; those without a date after, newest first.
    private static func dueFirst(_ a: Outstanding, _ b: Outstanding) -> Bool {
        switch (a.dueDate, b.dueDate) {
        case let (x?, y?): x < y
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil): a.createdAt > b.createdAt
        }
    }
}

/// Adds or edits one 应收 or 应付, and shows what has been received or paid against it.
struct OutstandingEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.baseCurrencyKey) private var baseCurrency = AppSettings.defaultBaseCurrency

    let item: Outstanding?
    @State private var direction: OutstandingDirection
    @State private var title: String
    @State private var counterparty: String
    @State private var amountText: String
    @State private var currencyCode: String
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var category: LedgerCategory?
    @State private var account: Account?
    @State private var note: String
    @State private var partlySettling = false
    @FocusState private var amountFocused: Bool

    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query(filter: #Predicate<Account> { !$0.isArchived }, sort: \Account.sortOrder) private var accounts: [Account]

    init(item: Outstanding?, direction: OutstandingDirection) {
        self.item = item
        _direction = State(initialValue: item?.direction ?? direction)
        _title = State(initialValue: item?.title ?? "")
        _counterparty = State(initialValue: item?.counterparty ?? "")
        _amountText = State(initialValue: item?.amount.inputText ?? "")
        _currencyCode = State(initialValue: item?.currencyCode
                              ?? UserDefaults.standard.string(forKey: AppSettings.baseCurrencyKey) ?? AppSettings.defaultBaseCurrency)
        _hasDueDate = State(initialValue: item?.dueDate != nil)
        _dueDate = State(initialValue: item?.dueDate ?? Calendar.current.startOfDay(for: .now))
        _category = State(initialValue: item?.category)
        _account = State(initialValue: item?.account)
        _note = State(initialValue: item?.note ?? "")
    }

    var body: some View {
        Form {
            if item == nil {
                Section {
                    Picker("类型", selection: $direction) {
                        Text("应收（别人欠我）").tag(OutstandingDirection.receivable)
                        Text("应付（我欠别人）").tag(OutstandingDirection.payable)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }

            Section {
                AmountField(text: $amountText, currencyCode: currencyCode, focused: $amountFocused)
                CurrencyPicker(title: "币种", code: $currencyCode)
            }

            Section {
                LabeledContent(direction == .receivable ? "谁欠我" : "欠谁") {
                    TextField("如 张三、装修师傅", text: $counterparty)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("事项") {
                    TextField("如 借款、项目尾款", text: $title)
                        .multilineTextAlignment(.trailing)
                }
                Toggle(direction == .receivable ? "预计收到日期" : "约定付款日期", isOn: $hasDueDate.animation())
                if hasDueDate {
                    DatePicker("日期", selection: $dueDate, displayedComponents: .date)
                }
            }

            Section {
                Picker("分类", selection: $category) {
                    Text("未分类").tag(LedgerCategory?.none)
                    ForEach(categories.filter { $0.kind == direction.categoryKind }) { Text($0.name).tag(Optional($0)) }
                }
                Picker(direction == .receivable ? "收款账户" : "付款账户", selection: $account) {
                    Text("不指定").tag(Account?.none)
                    ForEach(accounts) { Text($0.name).tag(Optional($0)) }
                }
            } footer: {
                Text(direction == .receivable
                     ? "不算进收入。收到钱时点「收到了」，按这里的分类和账户记一笔收入。"
                     : "不算进支出。付钱时点「付了」，按这里的分类和账户记一笔支出。")
            }

            Section {
                TextField("备注", text: $note, axis: .vertical)
            }

            if let item, !(item.settlements ?? []).isEmpty {
                Section {
                    ForEach((item.settlements ?? []).sorted { $0.date > $1.date }) { entry in
                        LabeledContent(DayText.dayWithWeekday(entry.date)) {
                            Text(entry.amount.money(entry.currencyCode))
                                .monospacedDigit()
                        }
                    }
                } header: {
                    Text(direction == .receivable ? "已收" : "已付")
                } footer: {
                    Text(item.isSettled ? "已结清。在账本里删掉某一笔，它会回到这里。"
                                        : "还差 \(item.remaining.money(item.currencyCode))。在账本里删掉某一笔，它会回到这里。")
                }
            }

            if let item, !item.isSettled {
                Section {
                    Button(direction == .receivable ? "记一笔收款…" : "记一笔付款…") { partlySettling = true }
                }
            }
        }
        .navigationTitle(item == nil ? (direction == .receivable ? "新建应收" : "新建应付") : "应收应付")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消", systemImage: "xmark", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", systemImage: "checkmark", role: .confirm, action: save)
                    .disabled(amount == nil || (title.trimmed.isEmpty && counterparty.trimmed.isEmpty))
            }
        }
        .onChange(of: direction) {
            if category?.kind != direction.categoryKind { category = nil }
        }
        .onAppear { if item == nil { amountFocused = true } }
        .sheet(isPresented: $partlySettling) {
            if let item { NavigationStack { SettleOutstandingView(item: item) } }
        }
    }

    private var amount: Decimal? {
        guard let value = Decimal(userInput: amountText), value > 0 else { return nil }
        return value
    }

    private func save() {
        guard let amount else { return }
        let target: Outstanding
        if let item {
            target = item
        } else {
            target = Outstanding(direction: direction, title: "", amount: amount)
            context.insert(target)
        }
        target.direction = direction
        target.title = title.trimmed.isEmpty ? String(localized: "欠款") : title.trimmed
        target.counterparty = counterparty.trimmed
        target.amount = amount
        target.currencyCode = currencyCode
        target.dueDate = hasDueDate ? Calendar.current.startOfDay(for: dueDate) : nil
        target.category = category
        target.account = account
        target.note = note.trimmed
        dismiss()
    }
}

/// Records part (or all) of what's owed: the amount, the day and the account can differ from the plan.
struct SettleOutstandingView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let item: Outstanding
    @Query(filter: #Predicate<Account> { !$0.isArchived }, sort: \Account.sortOrder) private var accounts: [Account]
    @State private var amountText: String
    @State private var account: Account?
    @State private var date = Date.now
    @FocusState private var amountFocused: Bool

    init(item: Outstanding) {
        self.item = item
        _amountText = State(initialValue: item.remaining.inputText)
        _account = State(initialValue: item.account)
    }

    var body: some View {
        Form {
            Section {
                AmountField(text: $amountText, currencyCode: item.currencyCode, focused: $amountFocused)
            } header: {
                Text(item.direction == .receivable ? "这次收到" : "这次付出")
            } footer: {
                Text(footer)
            }
            Section {
                Picker(item.direction == .receivable ? "收款账户" : "付款账户", selection: $account) {
                    Text("不指定").tag(Account?.none)
                    ForEach(accounts) { Text($0.name).tag(Optional($0)) }
                }
                DatePicker("日期", selection: $date, displayedComponents: .date)
            }
        }
        .navigationTitle(item.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消", systemImage: "xmark", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(item.direction == .receivable ? "记为收入" : "记为支出") {
                    guard let amount else { return }
                    item.settle(amount: amount, on: date, account: account, in: context)
                    dismiss()
                }
                .disabled(amount == nil)
            }
        }
        .onAppear { amountFocused = true }
    }

    private var amount: Decimal? {
        guard let value = Decimal(userInput: amountText), value > 0 else { return nil }
        return value
    }

    private var footer: String {
        let owed = item.remaining.money(item.currencyCode)
        guard let amount, amount < item.remaining else {
            return String(localized: "还差 \(owed)，记完就结清了。")
        }
        return String(localized: "还差 \(owed)，记完还剩 \((item.remaining - amount).money(item.currencyCode))。")
    }
}
