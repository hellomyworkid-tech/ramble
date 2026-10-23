import Charts
import SwiftData
import SwiftUI

/// Chart colors, validated with the dataviz palette checker against the card
/// surfaces (#FFFFFF light, #1C1C1E dark): every check passes in both modes.
enum ChartPalette {
    /// Categorical slot 1: spending, and every single-series chart.
    static let expense = Color(light: "#2a78d6", dark: "#3987e5")
    /// Categorical slot 2: income, only ever shown beside spending.
    static let income = Color(light: "#eb6834", dark: "#d95926")
    /// Hairline grid, one step off the surface.
    static let grid = Color(.separator)
}

struct StatsView: View {
    enum Period: String, CaseIterable, Identifiable {
        case month, year
        var id: Self { self }
        var title: LocalizedStringResource {
            switch self {
            case .month: "月"
            case .year: "年"
            }
        }
    }

    @AppStorage(AppSettings.baseCurrencyKey) private var baseCurrency = AppSettings.defaultBaseCurrency
    @State private var period: Period = .month
    @State private var anchor = Date.now

    var body: some View {
        StatsContent(period: $period, anchor: $anchor, baseCurrency: baseCurrency)
            .id("\(period.rawValue)-\(anchor.timeIntervalSince1970)")
            .navigationTitle("统计")
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StatsContent: View {
    @Binding var period: StatsView.Period
    @Binding var anchor: Date
    let baseCurrency: String

    @Query private var entries: [LedgerEntry]
    @Query private var budgets: [Budget]
    @State private var selectedDay: Date?
    @State private var selectedMonth: Date?

    private let interval: DateInterval

    init(period: Binding<StatsView.Period>, anchor: Binding<Date>, baseCurrency: String) {
        _period = period
        _anchor = anchor
        self.baseCurrency = baseCurrency
        let calendar = Calendar.current
        let unit: Calendar.Component = period.wrappedValue == .month ? .month : .year
        let interval = calendar.dateInterval(of: unit, for: anchor.wrappedValue) ?? DateInterval(start: .now, duration: 0)
        self.interval = interval
        let start = interval.start
        let end = interval.end
        _entries = Query(filter: #Predicate<LedgerEntry> { $0.date >= start && $0.date < end }, sort: \LedgerEntry.date)
    }

    var body: some View {
        List {
            Section {
                Picker("周期", selection: $period) {
                    ForEach(StatsView.Period.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                periodSwitcher
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

            Section {
                HStack(alignment: .top, spacing: 10) {
                    StatTile(title: "支出", value: total(.expense).money(baseCurrency))
                    StatTile(title: "收入", value: total(.income).money(baseCurrency))
                    StatTile(title: "结余", value: (total(.income) - total(.expense)).money(baseCurrency))
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } footer: {
                Text(period == .month
                     ? "日均支出 \(averagePerDay.money(baseCurrency))"
                     : "月均支出 \(averagePerMonth.money(baseCurrency))")
            }

            if expenses.isEmpty && incomes.isEmpty {
                ContentUnavailableView("这段时间还没有记账", systemImage: "chart.bar", description: Text("记几笔之后，这里会出现图表。"))
                    .listRowBackground(Color.clear)
            } else {
                if period == .month { dailySection } else { monthlySection }
                breakdownSection
                if period == .month {
                    budgetSection
                    largestSection
                }
            }
        }
    }

    private var periodSwitcher: some View {
        HStack {
            Button("上一个", systemImage: "chevron.left") { shift(-1) }
                .labelStyle(.iconOnly)
            Spacer()
            Text(period == .month ? interval.start.formatted(.dateTime.year().month(.wide)) : interval.start.formatted(.dateTime.year()))
                .font(.headline)
            Spacer()
            Button("下一个", systemImage: "chevron.right") { shift(1) }
                .labelStyle(.iconOnly)
                .disabled(interval.end > .now)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
    }

    private func shift(_ step: Int) {
        let unit: Calendar.Component = period == .month ? .month : .year
        if let next = Calendar.current.date(byAdding: unit, value: step, to: interval.start) {
            anchor = next
        }
    }

    // MARK: - Daily spending (month)

    private struct DayTotal: Identifiable {
        let day: Date
        let amount: Double
        var id: Date { day }
    }

    private var dailyTotals: [DayTotal] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: expenses) { calendar.startOfDay(for: $0.date) }
        return grouped.map { DayTotal(day: $0.key, amount: $0.value.reduce(0) { $0 + $1.baseAmount }.doubleValue) }
            .sorted { $0.day < $1.day }
    }

    private var dailySection: some View {
        Section {
            let totals = dailyTotals
            let average = averagePerDay.doubleValue
            Chart {
                ForEach(totals) { item in
                    BarMark(x: .value("日期", item.day, unit: .day), y: .value("支出", item.amount), width: .ratio(0.7))
                        .foregroundStyle(ChartPalette.expense)
                        .cornerRadius(3)
                        .opacity(selectedDay == nil || Calendar.current.isDate(item.day, inSameDayAs: selectedDay!) ? 1 : 0.35)
                }
                if average > 0 {
                    RuleMark(y: .value("日均", average))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, alignment: .trailing, spacing: 2) {
                            Text("日均 \(Decimal(average).money(baseCurrency))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .background(Color(.secondarySystemGroupedBackground))
                        }
                }
                if let selectedDay, let item = totals.first(where: { Calendar.current.isDate($0.day, inSameDayAs: selectedDay) }) {
                    RuleMark(x: .value("选中", item.day, unit: .day))
                        .foregroundStyle(Color.secondary.opacity(0.3))
                        .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            ChartTooltip(title: DayText.dayWithWeekday(item.day),
                                         rows: [(String(localized: "支出"), Decimal(item.amount).money(baseCurrency), ChartPalette.expense)])
                        }
                }
            }
            .chartXSelection(value: $selectedDay)
            .chartXScale(domain: interval.start...interval.end)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) {
                    AxisValueLabel(format: .dateTime.day())
                }
            }
            .chartYAxis { moneyAxis }
            .frame(height: 220)
            .padding(.vertical, 8)
            .accessibilityLabel(Text("每日支出柱状图"))
            .accessibilityValue(Text("\(totals.count) 天有支出，最多一天 \(Decimal(totals.map(\.amount).max() ?? 0).money(baseCurrency))"))
        } header: {
            Text("每日支出")
        } footer: {
            Text("按住图表左右拖动，查看每天的支出。")
        }
    }

    // MARK: - Monthly income vs spending (year)

    private struct MonthTotal: Identifiable {
        let month: Date
        let kind: String
        let amount: Double
        var id: String { "\(month.timeIntervalSince1970)-\(kind)" }
    }

    private var monthlyTotals: [MonthTotal] {
        let calendar = Calendar.current
        let expenseLabel = String(localized: "支出")
        let incomeLabel = String(localized: "收入")
        var result: [MonthTotal] = []
        for offset in 0..<12 {
            guard let month = calendar.date(byAdding: .month, value: offset, to: interval.start),
                  let range = calendar.dateInterval(of: .month, for: month)
            else { continue }
            // Half-open: DateInterval.contains would also count 00:00 on the 1st of next month.
            let spent = expenses.filter { range.holds($0.date) }.reduce(0) { $0 + $1.baseAmount }
            let earned = incomes.filter { range.holds($0.date) }.reduce(0) { $0 + $1.baseAmount }
            result.append(MonthTotal(month: month, kind: expenseLabel, amount: spent.doubleValue))
            result.append(MonthTotal(month: month, kind: incomeLabel, amount: earned.doubleValue))
        }
        return result
    }

    private var monthlySection: some View {
        Section {
            let totals = monthlyTotals
            let expenseLabel = String(localized: "支出")
            let incomeLabel = String(localized: "收入")
            Chart {
                ForEach(totals) { item in
                    BarMark(x: .value("月份", item.month, unit: .month), y: .value("金额", item.amount), width: .ratio(0.8))
                        .foregroundStyle(by: .value("类型", item.kind))
                        .position(by: .value("类型", item.kind))
                        .cornerRadius(2)
                }
                if let selectedMonth {
                    let month = Calendar.current.dateInterval(of: .month, for: selectedMonth)?.start ?? selectedMonth
                    let rows = totals.filter { Calendar.current.isDate($0.month, equalTo: month, toGranularity: .month) }
                    RuleMark(x: .value("选中", month, unit: .month))
                        .foregroundStyle(Color.secondary.opacity(0.15))
                        .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            ChartTooltip(title: month.formatted(.dateTime.month(.wide)), rows: rows.map { row in
                                (row.kind, Decimal(row.amount).money(baseCurrency), row.kind == expenseLabel ? ChartPalette.expense : ChartPalette.income)
                            })
                        }
                }
            }
            .chartForegroundStyleScale([expenseLabel: ChartPalette.expense, incomeLabel: ChartPalette.income])
            .chartLegend(position: .top, alignment: .leading, spacing: 14)
            .chartXSelection(value: $selectedMonth)
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) {
                    AxisValueLabel(format: .dateTime.month(.narrow), centered: true)
                }
            }
            .chartYAxis { moneyAxis }
            .frame(height: 240)
            .padding(.vertical, 8)

            // The table twin of the chart: every value readable without the chart.
            DisclosureGroup("按月明细") {
                ForEach(0..<12, id: \.self) { offset in
                    let spent = totals[offset * 2].amount
                    let earned = totals[offset * 2 + 1].amount
                    if spent > 0 || earned > 0 {
                        HStack {
                            Text(totals[offset * 2].month.formatted(.dateTime.month(.wide)))
                            Spacer()
                            Text("支出 \(Decimal(spent).money(baseCurrency))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text("收入 \(Decimal(earned).money(baseCurrency))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.footnote)
                    }
                }
            }
        } header: {
            Text("每月收支")
        }
    }

    @AxisContentBuilder
    private var moneyAxis: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                .foregroundStyle(ChartPalette.grid)
            AxisValueLabel {
                if let amount = value.as(Double.self) {
                    Text(Decimal(amount).formatted(.number.notation(.compactName)))
                }
            }
        }
    }

    // MARK: - Breakdown by category

    private struct CategoryTotal: Identifiable {
        let category: LedgerCategory?
        let amount: Decimal
        let entries: [LedgerEntry]
        var id: String { category.map { "\($0.persistentModelID.hashValue)" } ?? "none" }
    }

    private var categoryTotals: [CategoryTotal] {
        let grouped = Dictionary(grouping: expenses) { $0.category?.persistentModelID }
        return grouped.values.map { list in
            CategoryTotal(category: list.first?.category, amount: list.reduce(0) { $0 + $1.baseAmount }, entries: list)
        }
        .sorted { $0.amount > $1.amount }
    }

    private var breakdownSection: some View {
        Section("支出构成") {
            let totals = categoryTotals
            let spent = total(.expense)
            let largest = totals.first?.amount ?? 1
            ForEach(totals) { item in
                NavigationLink {
                    CategoryEntriesView(title: item.category?.name ?? String(localized: "未分类"),
                                        entries: item.entries.sorted { $0.date > $1.date },
                                        baseCurrency: baseCurrency)
                } label: {
                    HStack(spacing: 12) {
                        IconTile(symbol: item.category?.symbol ?? "questionmark", color: Color(hex: item.category?.colorHex ?? "#6E6E73"), size: 30)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(item.category?.name ?? String(localized: "未分类"))
                                Spacer()
                                Text(item.amount.money(baseCurrency))
                                    .monospacedDigit()
                            }
                            HStack(spacing: 8) {
                                ProportionBar(fraction: largest > 0 ? (item.amount / largest).doubleValue : 0)
                                Text((spent > 0 ? (item.amount / spent).doubleValue : 0).formatted(.percent.precision(.fractionLength(0))))
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Budgets and largest expenses (month)

    @ViewBuilder
    private var budgetSection: some View {
        let monthBudgets = budgets.sorted { ($0.category?.sortOrder ?? -1) < ($1.category?.sortOrder ?? -1) }
        if !monthBudgets.isEmpty {
            Section("预算") {
                ForEach(monthBudgets) { budget in
                    let spent = budget.category.map { category in
                        expenses.filter { $0.category == category }.reduce(0) { $0 + $1.baseAmount }
                    } ?? total(.expense)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(budget.category?.name ?? String(localized: "总预算"))
                            Spacer()
                            Text("\(spent.money(baseCurrency)) / \(budget.amount.money(baseCurrency))")
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        BudgetBar(fraction: budget.amount > 0 ? (spent / budget.amount).doubleValue : 0)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var largestSection: some View {
        let largest = expenses.sorted { $0.baseAmount > $1.baseAmount }.prefix(5)
        if !largest.isEmpty {
            Section("最大的几笔") {
                ForEach(Array(largest)) { entry in
                    EntryRow(entry: entry, baseCurrency: baseCurrency)
                }
            }
        }
    }

    // MARK: - Figures

    private var expenses: [LedgerEntry] { entries.filter { $0.kind == .expense } }
    private var incomes: [LedgerEntry] { entries.filter { $0.kind == .income } }

    private func total(_ kind: EntryKind) -> Decimal {
        entries.filter { $0.kind == kind }.reduce(0) { $0 + $1.baseAmount }
    }

    /// Spending divided by the days elapsed (the whole month once it is over).
    private var averagePerDay: Decimal {
        let calendar = Calendar.current
        let end = min(interval.end, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? interval.end)
        let days = max(1, calendar.dateComponents([.day], from: interval.start, to: end).day ?? 1)
        return (total(.expense) / Decimal(days)).rounded(scale: 2)
    }

    private var averagePerMonth: Decimal {
        let calendar = Calendar.current
        let months = interval.end > .now ? calendar.component(.month, from: .now) : 12
        return (total(.expense) / Decimal(max(1, months))).rounded(scale: 2)
    }
}

/// Label + value, proportional figures (they are standalone numbers, not a column).
private struct StatTile: View {
    let title: LocalizedStringResource
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

/// A thin single-hue bar for ranked lists.
private struct ProportionBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                // A lighter step of the same hue, so short bars still read as a share.
                Capsule()
                    .fill(ChartPalette.expense.opacity(0.15))
                Capsule()
                    .fill(ChartPalette.expense)
                    .frame(width: max(6, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// Selection read-out: text in text colors, identity from the swatch beside it.
private struct ChartTooltip: View {
    let title: String
    let rows: [(String, String, Color)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
            ForEach(rows, id: \.0) { label, value, color in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: 8, height: 8)
                    Text(label)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
    }
}

struct CategoryEntriesView: View {
    let title: String
    let entries: [LedgerEntry]
    let baseCurrency: String

    var body: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    EntryRow(entry: entry, baseCurrency: baseCurrency)
                }
            } footer: {
                Text("共 \(entries.count) 笔，\(entries.reduce(Decimal(0)) { $0 + $1.baseAmount }.money(baseCurrency))")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
