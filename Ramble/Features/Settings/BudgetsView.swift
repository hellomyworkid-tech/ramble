import SwiftData
import SwiftUI

struct BudgetsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(AppSettings.baseCurrencyKey) private var baseCurrency = AppSettings.defaultBaseCurrency

    @Query private var budgets: [Budget]
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query private var monthEntries: [LedgerEntry]

    /// What the amount alert is editing: nil category = the overall budget.
    private struct AmountTarget: Identifiable {
        let category: LedgerCategory?
        var id: PersistentIdentifier? { category?.persistentModelID }
    }

    @State private var amountTarget: AmountTarget?
    @State private var amountText = ""

    init() {
        let start = Date.now.startOfMonth()
        let expense = EntryKind.expense.rawValue
        _monthEntries = Query(filter: #Predicate<LedgerEntry> { $0.date >= start && $0.kindRaw == expense })
    }

    var body: some View {
        List {
            Section {
                let overall = budgets.first { $0.category == nil }
                Button {
                    edit(nil, current: overall?.amount)
                } label: {
                    BudgetRow(title: String(localized: "每月总预算"), symbol: "chart.pie.fill", color: .accentColor,
                              spent: totalSpent, budget: overall?.amount, currency: baseCurrency)
                }
                .buttonStyle(.plain)
            }

            Section {
                ForEach(categoryBudgets) { budget in
                    if let category = budget.category {
                        Button {
                            edit(category, current: budget.amount)
                        } label: {
                            BudgetRow(title: category.name, symbol: category.symbol, color: Color(hex: category.colorHex),
                                      spent: spent(in: category), budget: budget.amount, currency: baseCurrency)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .onDelete { offsets in
                    let list = categoryBudgets
                    offsets.forEach { context.delete(list[$0]) }
                }

                let available = categories.filter { category in
                    category.kind == .expense && !budgets.contains { $0.category == category }
                }
                if !available.isEmpty {
                    Menu {
                        ForEach(available) { category in
                            Button(category.name) { edit(category, current: nil) }
                        }
                    } label: {
                        Label("添加分类预算", systemImage: "plus.circle.fill")
                    }
                }
            } header: {
                Text("分类预算")
            } footer: {
                Text("本月支出接近或超过预算时，会在首页和账本里标出来。")
            }
        }
        .navigationTitle(Text(ScreenName.budgets))
        .alert(alertTitle, isPresented: Binding(get: { amountTarget != nil }, set: { if !$0 { amountTarget = nil } })) {
            TextField("金额", text: $amountText)
                .keyboardType(.decimalPad)
            Button("保存", action: saveAmount)
            if hasExistingBudget {
                Button("删除预算", role: .destructive, action: deleteBudget)
            }
            Button("取消", role: .cancel) { amountTarget = nil }
        } message: {
            Text("每月 \(baseCurrency)")
        }
    }

    private var categoryBudgets: [Budget] {
        budgets
            .filter { $0.category != nil }
            .sorted { ($0.category?.sortOrder ?? 0) < ($1.category?.sortOrder ?? 0) }
    }

    private var totalSpent: Decimal {
        monthEntries.reduce(0) { $0 + $1.baseAmount }
    }

    private func spent(in category: LedgerCategory) -> Decimal {
        monthEntries.filter { $0.category == category }.reduce(0) { $0 + $1.baseAmount }
    }

    private var alertTitle: String {
        guard let target = amountTarget else { return "" }
        return target.category.map { String(localized: "\($0.name)预算") } ?? String(localized: "每月总预算")
    }

    private var hasExistingBudget: Bool {
        guard let target = amountTarget else { return false }
        return budgets.contains { $0.category == target.category }
    }

    private func edit(_ category: LedgerCategory?, current: Decimal?) {
        amountText = current?.inputText ?? ""
        amountTarget = AmountTarget(category: category)
    }

    private func saveAmount() {
        guard let target = amountTarget else { return }
        defer { amountTarget = nil }
        guard let amount = Decimal(userInput: amountText), amount > 0 else { return }
        if let existing = budgets.first(where: { $0.category == target.category }) {
            existing.amount = amount
        } else {
            let budget = Budget(amount: amount)
            context.insert(budget)
            budget.category = target.category
        }
    }

    private func deleteBudget() {
        guard let target = amountTarget else { return }
        if let existing = budgets.first(where: { $0.category == target.category }) {
            context.delete(existing)
        }
        amountTarget = nil
    }
}

private struct BudgetRow: View {
    let title: String
    let symbol: String
    let color: Color
    let spent: Decimal
    let budget: Decimal?
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                IconTile(symbol: symbol, color: color, size: 28)
                Text(title)
                Spacer()
                if let budget {
                    Text("\(spent.money(currency)) / \(budget.money(currency))")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("未设置")
                        .foregroundStyle(.secondary)
                }
            }
            if let budget, budget > 0 {
                BudgetBar(fraction: (spent / budget).doubleValue)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}
