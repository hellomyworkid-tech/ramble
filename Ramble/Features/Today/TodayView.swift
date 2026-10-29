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
    @State private var showSettings = false
    @State private var showsOutstanding = false
    @Query private var outstandings: [Outstanding]

    init(selection: Binding<AppTab>) {
        _selection = selection
        let start = Date.now.startOfMonth()
        _monthEntries = Query(filter: #Predicate<LedgerEntry> { $0.date >= start })
    }

    var body: some View {
        NavigationStack {
            List {
                // The whole day at a glance, above the fold: each tile opens its full list.
                Section {
                    AskEntry { router.ask() }
                        .padding(.bottom, 2)
                    Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                        GridRow {
                            tasksTile
                            spendingTile
                        }
                        GridRow {
                            outstandingTile
                            upcomingTile
                        }
                    }
                    HStack(spacing: 10) {
                        reviewChip(.week)
                        reviewChip(.month)
                    }
                    .padding(.top, 10)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 10, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section {
                    if todayTasks.isEmpty {
                        Text("今天没有待办，轻松一下")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(todayTasks.prefix(Self.listLimit)) { task in
                            TaskRow(task: task)
                                .contentShape(.rect)
                                .onTapGesture { editingTask = task }
                        }
                        if todayTasks.count > Self.listLimit {
                            moreRow(todayTasks.count - Self.listLimit) { selection = .tasks }
                        }
                    }
                } header: {
                    HStack {
                        Text("今天要做")
                        Spacer()
                        Button("全部") { selection = .tasks }
                            .font(.subheadline)
                            .textCase(nil)
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
            .sheet(isPresented: $showSettings) {
                NavigationStack { SettingsView() }
            }
            .navigationDestination(isPresented: $showsOutstanding) {
                OutstandingListView()
            }
        }
    }

    /// Lists on this page stop at three; the rest is a tap away.
    private static let listLimit = 3

    private func moreRow(_ count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text("还有 \(count) 项")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tiles

    private var tasksTile: some View {
        DashboardTile(title: "待办", symbol: "checkmark", color: ModuleColor.tasks) {
            selection = .tasks
        } content: {
            Text("\(todayTasks.count)")
                .font(.title2.weight(.bold))
                .monospacedDigit()
            Group {
                if overdueCount > 0 {
                    Text("其中 \(overdueCount) 项已过期")
                        .foregroundStyle(.red)
                } else {
                    Text(todayTasks.first?.title ?? String(localized: "今天没有待办"))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .lineLimit(1)
        }
    }

    /// This month's spending with the budget folded in (it used to be a separate card further down).
    private var spendingTile: some View {
        let budget = budgets.first { $0.category == nil }
        // Tile titles have their own keys: the narrow tile needs shorter English than the full phrases.
        return DashboardTile(title: LocalizedStringResource("tile.spending", defaultValue: "本月支出"), symbol: "creditcard",
                             color: ModuleColor.money) {
            selection = .ledger
        } content: {
            Text(monthExpense.money(baseCurrency, wholeNumbers: true))
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let budget, budget.amount > 0 {
                let remaining = budget.amount - monthExpense
                BudgetBar(fraction: fraction(of: budget))
                Text(remaining >= 0 ? "预算还剩 \(remaining.money(baseCurrency, wholeNumbers: true))"
                                    : "已超支 \((-remaining).money(baseCurrency, wholeNumbers: true))")
                    .font(.caption)
                    .foregroundStyle(remaining >= 0 ? Color.secondary : Color.red)
                    .lineLimit(1)
            } else {
                Text("本月收入 \(monthIncome.money(baseCurrency, wholeNumbers: true))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// Money owed either way: on the first screen, since it's easy to forget and costly when you do.
    private var outstandingTile: some View {
        let open = outstandings.filter { !$0.isSettled }
        let receivable = open.filter { $0.direction == .receivable }
        let payable = open.filter { $0.direction == .payable }
        return DashboardTile(title: LocalizedStringResource("tile.owed", defaultValue: "应收应付"), symbol: "arrow.left.arrow.right",
                             color: ModuleColor.expiry) {
            showsOutstanding = true
        } content: {
            if open.isEmpty {
                Text("暂无")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.tertiary)
                Text("谁欠谁的钱记在这里")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    owedLine("应收", total: Outstanding.total(receivable, base: baseCurrency), count: receivable.count,
                             color: ModuleColor.money)
                    owedLine("应付", total: Outstanding.total(payable, base: baseCurrency), count: payable.count,
                             color: ModuleColor.bills)
                }
            }
        }
    }

    private func owedLine(_ label: LocalizedStringResource, total: Decimal, count: Int, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(count == 0 ? "—" : total.money(baseCurrency, wholeNumbers: true))
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(count == 0 ? Color.secondary : color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private var upcomingTile: some View {
        DashboardTile(title: "即将到期", symbol: "calendar", color: ModuleColor.bills) {
            selection = .reminders
        } content: {
            Text("\(upcoming.count)")
                .font(.title2.weight(.bold))
                .monospacedDigit()
            Text(upcoming.first.map { "\($0.name) · \(DayText.countdown(to: $0.date))" } ?? String(localized: "近期没有要付的账单或到期的东西"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - Review

    /// 「上周周报」「本月月报」 side by side: the spending at a glance, the report a tap away.
    private func reviewChip(_ kind: PeriodReport.Kind) -> some View {
        let period = ReportBuilder.defaultPeriod(kind)
        let spent = LedgerSummary.expenses(in: period.interval, context: context)
        return Button {
            router.openReport(kind)
        } label: {
            HStack(spacing: 10) {
                IconTile(symbol: kind == .week ? "calendar.badge.clock" : "chart.bar.xaxis",
                         color: kind == .week ? ModuleColor.tasks : ModuleColor.money, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("\(period.label) · 支出 \(spent.money(baseCurrency, wholeNumbers: true))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private func fraction(of budget: Budget) -> Double {
        guard budget.amount > 0 else { return 0 }
        return (monthExpense / budget.amount).doubleValue
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

    private var monthIncome: Decimal {
        monthEntries
            .filter { $0.kind == .income }
            .reduce(0) { $0 + $1.baseAmount }
    }

    private var overdueCount: Int {
        todayTasks.filter { $0.isOverdue() }.count
    }

    /// Bills due within a week and expiry dates within a month; the Reminders tab has the rest.
    private var upcoming: [UpcomingItem] {
        let soonBills = bills
            .filter { DayText.daysUntil($0.nextDueDate) <= 7 }
            .map(UpcomingItem.bill)
        let soonExpiries = expiries
            .filter { DayText.daysUntil($0.expiryDate) <= 30 }
            .map(UpcomingItem.expiry)
        return (soonBills + soonExpiries).sorted { $0.date < $1.date }
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

    var name: String {
        switch self {
        case .bill(let bill): bill.name
        case .expiry(let item): item.name
        }
    }
}

/// One of the four squares at the top of Today: a figure, a line under it, and a tap to the full list.
private struct DashboardTile<Content: View>: View {
    let title: LocalizedStringResource
    let symbol: String
    let color: Color
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(color, in: .circle)
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
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
                // One line: the name, then an example as far as it fits.
                HStack(spacing: 8) {
                    Text("问问你记过的")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .layoutPriority(1)
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
            .padding(.vertical, 11)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("问一问")
        .accessibilityHint("用一句话问你的账目、待办和笔记")
    }
}
