import SwiftData
import SwiftUI

/// Entries added up per category, largest first. A subcategory (from an imported ledger)
/// counts toward its parent, as in the weekly and monthly reports.
struct CategoryTotal: Identifiable {
    /// nil: entries without a category, or the transfers row.
    let category: LedgerCategory?
    let amount: Decimal
    let count: Int

    var id: PersistentIdentifier? { category?.persistentModelID }

    static func top(of entry: LedgerEntry) -> LedgerCategory? {
        entry.category?.parent ?? entry.category
    }

    static func totals(of entries: [LedgerEntry]) -> [CategoryTotal] {
        Dictionary(grouping: entries) { top(of: $0)?.persistentModelID }
            .values
            .map { list in
                CategoryTotal(category: top(of: list[0]), amount: list.reduce(0) { $0 + $1.baseAmount }, count: list.count)
            }
            .sorted { lhs, rhs in
                // Equal amounts keep the categories' own order, so rows don't swap places.
                if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
                return (lhs.category?.sortOrder ?? .max) < (rhs.category?.sortOrder ?? .max)
            }
    }
}

/// A category's total for the period, with its share of all spending (or income) and how many
/// entries make it up. Transfers show their total and count only.
struct CategoryTotalRow: View {
    let total: CategoryTotal
    let kind: EntryKind
    /// The largest category's amount, which gets the full-length bar.
    let largest: Decimal
    /// Everything of this kind in the period, for the percentage.
    let sum: Decimal
    let baseCurrency: String

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, color: color, size: 30)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(name)
                        .lineLimit(1)
                    Text("\(total.count) 笔")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(total.amount.money(baseCurrency))
                        .monospacedDigit()
                        .foregroundStyle(kind == .income ? ModuleColor.money : Color.primary)
                }
                if kind != .transfer {
                    HStack(spacing: 8) {
                        ProportionBar(fraction: largest > 0 ? (total.amount / largest).doubleValue : 0,
                                      color: kind == .income ? ModuleColor.money : ChartPalette.expense)
                        Text(shareText)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// A sliver of the total reads 「<1%」, not 「0%」.
    private var shareText: String {
        let share = sum > 0 ? (total.amount / sum).doubleValue : 0
        if share > 0, share < 0.005 { return "<" + 0.01.formatted(.percent.precision(.fractionLength(0))) }
        return share.formatted(.percent.precision(.fractionLength(0)))
    }

    private var name: String {
        if kind == .transfer { return String(localized: EntryKind.transfer.title) }
        return total.category?.name ?? String(localized: "未分类")
    }

    private var symbol: String {
        kind == .transfer ? "arrow.left.arrow.right" : total.category?.symbol ?? "questionmark"
    }

    private var color: Color {
        kind == .transfer ? ModuleColor.neutral : Color(hex: total.category?.colorHex ?? "#6E6E73")
    }
}

/// One category's entries over a period (a month from 账本, a month or a year from 统计), day by
/// day. Live, so an entry moved to another category while editing leaves the list.
struct CategoryLedgerView: View {
    let kind: EntryKind
    /// The top-level category; nil for 未分类. Not used for transfers.
    let category: LedgerCategory?
    /// Shown above the total, like 「2026年11月」.
    let periodTitle: String
    let baseCurrency: String

    @Query private var entries: [LedgerEntry]
    @State private var editingEntry: LedgerEntry?
    @State private var confirmDelete: LedgerEntry?

    init(kind: EntryKind, category: LedgerCategory?, interval: DateInterval, periodTitle: String, baseCurrency: String) {
        self.kind = kind
        self.category = category
        self.periodTitle = periodTitle
        self.baseCurrency = baseCurrency
        let start = interval.start
        let end = interval.end
        _entries = Query(filter: #Predicate<LedgerEntry> { $0.date >= start && $0.date < end },
                         sort: \LedgerEntry.date, order: .reverse)
    }

    var body: some View {
        let shown = entries.filter { entry in
            entry.kind == kind && (kind == .transfer || CategoryTotal.top(of: entry)?.persistentModelID == category?.persistentModelID)
                && !PendingDeletion.shared.hides(entry)
        }
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(periodTitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(shown.reduce(Decimal(0)) { $0 + $1.baseAmount }.money(baseCurrency))
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(kind == .income ? ModuleColor.money : Color.primary)
                    Text("\(shown.count) 笔")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            EntriesByDay(entries: shown, baseCurrency: baseCurrency, totalKind: kind, confirmDelete: $confirmDelete) { editingEntry = $0 }
        }
        .overlay {
            if shown.isEmpty {
                ContentUnavailableView("这段时间没有这一类的记录", systemImage: "tray")
            }
        }
        .deletionUndoBar()
        .entryDeletionAlert($confirmDelete)
        .navigationTitle(kind == .transfer ? String(localized: EntryKind.transfer.title) : category?.name ?? String(localized: "未分类"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingEntry) { entry in
            NavigationStack { EntryEditorView(entry: entry) }
        }
    }
}

/// Entries in one section per day, newest first: tap one to edit it, swipe to delete (it asks
/// first, then there's 撤销). Each day's header adds up its entries of `totalKind`, and names the
/// year when it isn't this one (search results reach back years).
struct EntriesByDay: View {
    let entries: [LedgerEntry]
    let baseCurrency: String
    var totalKind = EntryKind.expense
    /// Set by 删除. The list this is in shows the question, with `entryDeletionAlert`.
    @Binding var confirmDelete: LedgerEntry?
    let onEdit: (LedgerEntry) -> Void

    var body: some View {
        let byDay = Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.date) }
        ForEach(byDay.keys.sorted(by: >), id: \.self) { day in
            Section {
                ForEach(byDay[day] ?? []) { entry in
                    EntryRow(entry: entry, baseCurrency: baseCurrency)
                        .contentShape(.rect)
                        .onTapGesture { onEdit(entry) }
                        .swipeActions(allowsFullSwipe: false) {
                            SwipeDeleteButton { confirmDelete = entry }
                        }
                }
            } header: {
                HStack {
                    Text(DayText.dayWithWeekday(day)
                         + (Calendar.current.isDate(day, equalTo: .now, toGranularity: .year) ? "" : " · \(day.formatted(.dateTime.year()))"))
                    Spacer()
                    let sum = (byDay[day] ?? []).filter { $0.kind == totalKind }.reduce(Decimal(0)) { $0 + $1.baseAmount }
                    if sum > 0 {
                        switch totalKind {
                        case .expense: Text("支出 \(sum.money(baseCurrency))").monospacedDigit()
                        case .income: Text("收入 \(sum.money(baseCurrency))").monospacedDigit()
                        case .transfer: EmptyView()
                        }
                    }
                }
            }
        }
    }
}

extension View {
    /// What 删除 in `EntriesByDay` asks, for the list it's in: `EntriesByDay` is only rows.
    func entryDeletionAlert(_ entry: Binding<LedgerEntry?>) -> some View {
        modifier(EntryDeletionAlert(entry: entry))
    }
}

private struct EntryDeletionAlert: ViewModifier {
    @Binding var entry: LedgerEntry?
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        content.deletionAlert(String(localized: "删除这笔记录？"), item: $entry) { entry in
            Button("删除", role: .destructive) {
                PendingDeletion.shared.delete([entry], message: String(localized: "已删除「\(entry.displayTitle)」"), in: context)
            }
        } message: { entry in
            Text("「\(entry.displayTitle + " " + entry.amount.money(entry.currencyCode))」")
        }
    }
}
