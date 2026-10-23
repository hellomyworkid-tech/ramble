import SwiftData
import SwiftUI

enum LedgerRoute: Hashable, Identifiable {
    case stats, accounts, categories, budgets
    var id: Self { self }
}

struct LedgerView: View {
    @AppStorage(AppSettings.baseCurrencyKey) private var baseCurrency = AppSettings.defaultBaseCurrency
    @State private var month = Date.now.startOfMonth()
    @State private var isCreating = false
    @State private var route: LedgerRoute?

    var body: some View {
        NavigationStack {
            MonthLedgerList(month: $month, baseCurrency: baseCurrency)
                .navigationTitle("账本")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("统计", systemImage: "chart.bar.xaxis") { route = .stats }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("管理", systemImage: "slider.horizontal.3") {
                            Button(String(localized: ScreenName.accounts), systemImage: "creditcard") { route = .accounts }
                            Button(String(localized: ScreenName.categories), systemImage: "square.grid.2x2") { route = .categories }
                            Button(String(localized: ScreenName.budgets), systemImage: "chart.pie") { route = .budgets }
                        }
                    }
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("记一笔", systemImage: "plus") { isCreating = true }
                    }
                }
                .navigationDestination(item: $route) { route in
                    switch route {
                    case .stats: StatsView()
                    case .accounts: AccountsView()
                    case .categories: CategoriesView()
                    case .budgets: BudgetsView()
                    }
                }
                .sheet(isPresented: $isCreating) {
                    NavigationStack { EntryEditorView(entry: nil) }
                }
        }
    }
}

/// The selected month's summary and entries, grouped by day.
private struct MonthLedgerList: View {
    @Binding var month: Date
    let baseCurrency: String

    @Environment(\.modelContext) private var context
    @Query private var entries: [LedgerEntry]
    @Query private var budgets: [Budget]
    @State private var editingEntry: LedgerEntry?

    init(month: Binding<Date>, baseCurrency: String) {
        _month = month
        self.baseCurrency = baseCurrency
        let interval = month.wrappedValue.monthInterval()
        let start = interval.start
        let end = interval.end
        _entries = Query(filter: #Predicate<LedgerEntry> { $0.date >= start && $0.date < end },
                         sort: \LedgerEntry.date, order: .reverse)
    }

    var body: some View {
        List {
            Section {
                MonthSwitcher(month: $month)
                summary
                OutstandingSummaryRow(baseCurrency: baseCurrency)
            }

            ForEach(days, id: \.self) { day in
                Section {
                    ForEach(entriesByDay[day] ?? []) { entry in
                        EntryRow(entry: entry, baseCurrency: baseCurrency)
                            .contentShape(.rect)
                            .onTapGesture { editingEntry = entry }
                            .swipeActions {
                                Button("删除", systemImage: "trash", role: .destructive) {
                                    context.delete(entry)
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text(DayText.dayWithWeekday(day))
                        Spacer()
                        let spent = total(of: .expense, in: entriesByDay[day] ?? [])
                        if spent > 0 {
                            Text("支出 \(spent.money(baseCurrency))")
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("这个月还没有记账", systemImage: "book.closed", description: Text("点右上角 +，或者在下方直接说出来"))
                    .padding(.top, 160)
            }
        }
        .sheet(item: $editingEntry) { entry in
            NavigationStack { EntryEditorView(entry: entry) }
        }
    }

    @ViewBuilder
    private var summary: some View {
        let expense = total(of: .expense, in: entries)
        let income = total(of: .income, in: entries)
        VStack(alignment: .leading, spacing: 14) {
            // Spending first and large; income and balance beneath it in two even columns.
            SummaryFigure(title: "支出", value: expense.money(baseCurrency), emphasized: true)
            HStack(alignment: .top, spacing: 12) {
                SummaryFigure(title: "收入", value: income.money(baseCurrency))
                    .frame(maxWidth: .infinity, alignment: .leading)
                SummaryFigure(title: "结余", value: (income - expense).money(baseCurrency),
                              tint: income - expense < 0 ? ModuleColor.warning : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let budget = budgets.first(where: { $0.category == nil }), budget.amount > 0 {
                let fraction = (expense / budget.amount).doubleValue
                VStack(alignment: .leading, spacing: 6) {
                    BudgetBar(fraction: fraction)
                    Text("预算 \(budget.amount.money(baseCurrency)) · 已用 \(fraction.formatted(.percent.precision(.fractionLength(0))))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var entriesByDay: [Date: [LedgerEntry]] {
        Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.date) }
    }

    private var days: [Date] {
        entriesByDay.keys.sorted(by: >)
    }

    private func total(of kind: EntryKind, in list: [LedgerEntry]) -> Decimal {
        list.filter { $0.kind == kind }.reduce(0) { $0 + $1.baseAmount }
    }
}

private struct SummaryFigure: View {
    let title: LocalizedStringResource
    let value: String
    var emphasized = false
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(value)
                .font(emphasized ? .largeTitle.weight(.bold) : .title3.weight(.semibold))
                .foregroundStyle(tint ?? .primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .accessibilityElement(children: .combine)
    }
}

struct MonthSwitcher: View {
    @Binding var month: Date

    var body: some View {
        HStack {
            Button("上个月", systemImage: "chevron.left") { shift(-1) }
                .labelStyle(.iconOnly)
            Spacer()
            Text(month.formatted(.dateTime.year().month(.wide)))
                .font(.headline)
            Spacer()
            Button("下个月", systemImage: "chevron.right") { shift(1) }
                .labelStyle(.iconOnly)
                .disabled(month >= Date.now.startOfMonth())
        }
        .buttonStyle(.borderless)
    }

    private func shift(_ months: Int) {
        if let next = Calendar.current.date(byAdding: .month, value: months, to: month) {
            month = next.startOfMonth()
        }
    }
}

struct EntryRow: View {
    let entry: LedgerEntry
    let baseCurrency: String

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.displayTitle)
                        .lineLimit(1)
                    if !(entry.attachments ?? []).isEmpty {
                        Image(systemName: "paperclip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("有照片"))
                    }
                }
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(amountText)
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(entry.kind == .income ? ModuleColor.money : Color.primary)
                if entry.currencyCode != baseCurrency {
                    Text("≈ \(entry.baseAmount.money(baseCurrency))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var symbol: String {
        if entry.kind == .transfer { return "arrow.left.arrow.right" }
        return entry.category?.symbol ?? "questionmark"
    }

    private var color: Color {
        if entry.kind == .transfer { return ModuleColor.neutral }
        return Color(hex: entry.category?.colorHex ?? "#6E6E73")
    }

    private var amountText: String {
        let money = entry.amount.money(entry.currencyCode)
        switch entry.kind {
        case .expense: return "−" + money
        case .income: return "+" + money
        case .transfer: return money
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if entry.kind == .transfer {
            parts.append("\(entry.account?.name ?? "?") → \(entry.toAccount?.name ?? "?")")
        } else {
            if !entry.note.isEmpty, let category = entry.category { parts.append(category.name) }
            if let account = entry.account { parts.append(account.name) }
        }
        parts.append(entry.date.formatted(date: .omitted, time: .shortened))
        return parts.joined(separator: " · ")
    }
}
