import SwiftData
import SwiftUI

struct TodayView: View {
    @Binding var selection: AppTab
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context
    @AppStorage(AppSettings.baseCurrencyKey) private var baseCurrency = AppSettings.defaultBaseCurrency

    @Query(filter: #Predicate<TaskItem> { !$0.isCompleted }) private var openTasks: [TaskItem]
    @Query(filter: #Predicate<Bill> { $0.isActive }, sort: \Bill.nextDueDate) private var bills: [Bill]
    @Query(filter: #Predicate<ExpiryItem> { !$0.isArchived }, sort: \ExpiryItem.expiryDate) private var expiries: [ExpiryItem]
    @Query private var monthEntries: [LedgerEntry]
    @Query private var budgets: [Budget]

    @State private var editingTask: TaskItem?
    @State private var editingBill: Bill?
    @State private var editingExpiry: ExpiryItem?
    @State private var payingBill: Bill?
    @State private var showSettings = false

    init(selection: Binding<AppTab>) {
        _selection = selection
        let start = Date.now.startOfMonth()
        _monthEntries = Query(filter: #Predicate<LedgerEntry> { $0.date >= start })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    AskEntry { router.ask() }
                        .padding(.bottom, 2)
                    HStack(spacing: 10) {
                        SummaryTile(symbol: "checkmark", color: ModuleColor.tasks, value: "\(todayTasks.count)", title: "待办")
                        SummaryTile(symbol: "creditcard", color: ModuleColor.money,
                                    value: monthExpense.money(baseCurrency, wholeNumbers: true), title: "本月支出")
                        SummaryTile(symbol: "calendar", color: ModuleColor.bills, value: "\(billsThisWeek.count)", title: "7 天内账单")
                    }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 10, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section {
                    if todayTasks.isEmpty {
                        Text("今天没有待办，轻松一下")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(todayTasks) { task in
                            TaskRow(task: task)
                                .contentShape(.rect)
                                .onTapGesture { editingTask = task }
                        }
                    }
                } header: {
                    HStack {
                        Text("待办")
                        Spacer()
                        Button("全部") { selection = .tasks }
                            .font(.subheadline)
                            .textCase(nil)
                    }
                }
                .headerProminence(.increased)

                Section {
                    reviewRow(.week)
                    reviewRow(.month)
                } header: {
                    Text("回顾")
                }
                .headerProminence(.increased)

                Section("本月预算") {
                    budgetCard
                }
                .headerProminence(.increased)

                Section("即将到期") {
                    if upcoming.isEmpty {
                        Text("近期没有要处理的账单和证件")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(upcoming) { item in
                        switch item {
                        case .bill(let bill):
                            BillRow(bill: bill)
                                .contentShape(.rect)
                                .onTapGesture { editingBill = bill }
                                .swipeActions(edge: .leading) {
                                    Button("已支付", systemImage: "checkmark") { payingBill = bill }
                                        .tint(ModuleColor.money)
                                }
                                .contextMenu {
                                    Button("已支付", systemImage: "checkmark.circle") { payingBill = bill }
                                    Button("编辑", systemImage: "pencil") { editingBill = bill }
                                }
                        case .expiry(let expiry):
                            ExpiryRow(item: expiry)
                                .contentShape(.rect)
                                .onTapGesture { editingExpiry = expiry }
                        }
                    }
                }
                .headerProminence(.increased)
            }
            .navigationTitle("今天")
            .navigationSubtitle(Date.now.formatted(.dateTime.month().day().weekday(.wide)))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("设置", systemImage: "gearshape") { showSettings = true }
                }
            }
            .sheet(item: $editingTask) { task in
                NavigationStack { TaskEditorView(task: task) }
            }
            .sheet(item: $editingBill) { bill in
                NavigationStack { BillEditorView(bill: bill) }
            }
            .sheet(item: $editingExpiry) { item in
                NavigationStack { ExpiryEditorView(item: item) }
            }
            .sheet(item: $payingBill) { bill in
                NavigationStack { MarkPaidView(bill: bill) }
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack { SettingsView() }
            }
        }
    }

    // MARK: - Review

    /// "上周 · 支出 ¥1,900，比前一周多 ¥1,620（+579%）"
    private func reviewRow(_ kind: PeriodReport.Kind) -> some View {
        let period = ReportBuilder.defaultPeriod(kind)
        let previous = PeriodResolver.samePoint(in: ReportBuilder.shifted(period, kind: kind, by: -1), for: period, now: .now)
        let spent = LedgerSummary.expenses(in: period.interval, context: context)
        let before = LedgerSummary.expenses(in: previous.interval, context: context)
        let weekLabel = String(localized: "前一周") + (period.holds(.now) ? String(localized: "同期") : "")
        let change = QueryRunner.changeSentence(spent, against: before, label: kind == .week ? weekLabel : previous.label)
        return Button {
            router.openReport(kind)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: kind == .week ? "calendar.badge.clock" : "chart.bar.xaxis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(kind == .week ? ModuleColor.tasks : ModuleColor.money, in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(period.label)\(kind.title)")
                        .foregroundStyle(.primary)
                    Text(change.map { String(localized: "支出 \(spent.money(baseCurrency))，\($0)") }
                         ?? String(localized: "支出 \(spent.money(baseCurrency))"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Budget

    @ViewBuilder
    private var budgetCard: some View {
        let budget = budgets.first { $0.category == nil }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(monthExpense.money(baseCurrency))
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                if let budget {
                    Text("/ \(budget.amount.money(baseCurrency))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(fraction(of: budget).formatted(.percent.precision(.fractionLength(0))))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if let budget {
                BudgetBar(fraction: fraction(of: budget))
                let remaining = budget.amount - monthExpense
                Text(remaining >= 0
                     ? "剩余 \(remaining.money(baseCurrency)) · 本月还剩 \(daysLeftInMonth) 天"
                     : "已超支 \((-remaining).money(baseCurrency))")
                    .font(.footnote)
                    .foregroundStyle(remaining >= 0 ? Color.secondary : Color.red)
            } else {
                Button("设置每月预算") { showSettings = true }
                    .font(.subheadline)
            }
        }
        .padding(.vertical, 4)
    }

    private func fraction(of budget: Budget) -> Double {
        guard budget.amount > 0 else { return 0 }
        return (monthExpense / budget.amount).doubleValue
    }

    private var daysLeftInMonth: Int {
        let calendar = Calendar.current
        let days = calendar.range(of: .day, in: .month, for: .now)?.count ?? 30
        return days - calendar.component(.day, from: .now) + 1
    }

    // MARK: - Derived data

    private var todayTasks: [TaskItem] {
        openTasks
            .filter { $0.isDueByEndOfToday() }
            .sorted { lhs, rhs in
                if lhs.priorityRaw != rhs.priorityRaw { return lhs.priorityRaw > rhs.priorityRaw }
                return (lhs.dueDate ?? .distantFuture) < (rhs.dueDate ?? .distantFuture)
            }
    }

    private var monthExpense: Decimal {
        monthEntries
            .filter { $0.kind == .expense }
            .reduce(0) { $0 + $1.baseAmount }
    }

    private var billsThisWeek: [Bill] {
        bills.filter { DayText.daysUntil($0.nextDueDate) <= 7 }
    }

    private var upcoming: [UpcomingItem] {
        let soonBills = bills
            .filter { DayText.daysUntil($0.nextDueDate) <= 30 }
            .map(UpcomingItem.bill)
        let soonExpiries = expiries
            .filter { DayText.daysUntil($0.expiryDate) <= 90 }
            .map(UpcomingItem.expiry)
        return (soonBills + soonExpiries)
            .sorted { $0.date < $1.date }
            .prefix(6)
            .map { $0 }
    }
}

private enum UpcomingItem: Identifiable {
    case bill(Bill)
    case expiry(ExpiryItem)

    var id: PersistentIdentifier {
        switch self {
        case .bill(let bill): bill.persistentModelID
        case .expiry(let item): item.persistentModelID
        }
    }

    var date: Date {
        switch self {
        case .bill(let bill): bill.nextDueDate
        case .expiry(let item): item.expiryDate
        }
    }
}

/// The way into 问一问: shaped like a search field, with an example of what it answers.
private struct AskEntry: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("问问你记过的")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("比如：这个月吃饭花了多少？下周有哪些账单？")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("问一问")
        .accessibilityHint("用一句话问你的账目、待办和笔记")
    }
}
