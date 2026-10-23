import Foundation
import SwiftData
import WidgetKit

/// Keeps the widgets current: writes the summary they read after changes, and takes in tasks
/// ticked off on a widget while the app wasn't running.
enum WidgetBridge {
    private static var pendingRefresh: Task<Void, Never>?

    /// Debounced: a burst of saves writes one summary.
    static func setNeedsRefresh(container: ModelContainer = AppSchema.shared) {
        pendingRefresh?.cancel()
        pendingRefresh = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            refresh(context: container.mainContext)
        }
    }

    static func refresh(context: ModelContext, now: Date = .now) {
        let snapshot = makeSnapshot(context: context, now: now)
        // Skip the reload when nothing the widgets show has changed.
        if let current = WidgetStore.load(), current.sameContent(as: snapshot) { return }
        if WidgetStore.save(snapshot) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Records completions made on a widget. Returns how many tasks changed.
    @discardableResult
    static func applyPendingCompletions(context: ModelContext, now: Date = .now) -> Int {
        let pending = WidgetStore.pendingCompletions()
        guard !pending.isEmpty else { return 0 }
        var changed = 0
        for id in pending {
            if let task = ModelRef.fetch(TaskItem.self, id, in: context), !task.isCompleted {
                task.toggleCompletion(now: now)
                changed += 1
            }
        }
        try? context.save()
        WidgetStore.clearPendingCompletions(pending)
        return changed
    }

    static func makeSnapshot(context: ModelContext, now: Date = .now, calendar: Calendar = .current) -> WidgetSnapshot {
        let startOfToday = calendar.startOfDay(for: now)
        let endOfTomorrow = calendar.date(byAdding: .day, value: 2, to: startOfToday) ?? now
        let open = (try? context.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { !$0.isCompleted && $0.dueDate != nil },
            sortBy: [SortDescriptor(\.dueDate)]))) ?? []
        let tasks = open
            .filter { ($0.dueDate ?? .distantFuture) < endOfTomorrow }
            .sorted { lhs, rhs in
                // Overdue and timed first, then by priority.
                if lhs.dueDate != rhs.dueDate { return (lhs.dueDate ?? .distantFuture) < (rhs.dueDate ?? .distantFuture) }
                return lhs.priorityRaw > rhs.priorityRaw
            }
            .prefix(30)
            .map { WidgetSnapshot.Task(id: ModelRef.encode($0.persistentModelID), title: $0.title, due: $0.dueDate,
                                       hasDueTime: $0.hasDueTime, priority: $0.priorityRaw) }

        let month = LedgerSummary.interval(.thisMonth, now: now, calendar: calendar)
        let today = LedgerSummary.interval(.today, now: now, calendar: calendar)
        let monthStart = month.start, monthEnd = month.end
        let monthEntries = (try? context.fetch(FetchDescriptor<LedgerEntry>(
            predicate: #Predicate { $0.date >= monthStart && $0.date < monthEnd }))) ?? []
        let monthExpense = monthEntries.filter { $0.kind == .expense }.reduce(Decimal(0)) { $0 + $1.baseAmount }
        let monthIncome = monthEntries.filter { $0.kind == .income }.reduce(Decimal(0)) { $0 + $1.baseAmount }
        let todayExpense = monthEntries.filter { $0.kind == .expense && today.holds($0.date) }.reduce(Decimal(0)) { $0 + $1.baseAmount }

        let billHorizon = calendar.date(byAdding: .day, value: 30, to: startOfToday) ?? now
        let expiryHorizon = calendar.date(byAdding: .day, value: 60, to: startOfToday) ?? now
        let bills = ((try? context.fetch(FetchDescriptor<Bill>(predicate: #Predicate { $0.isActive }))) ?? [])
            .filter { $0.nextDueDate >= startOfToday && $0.nextDueDate < billHorizon }
            .map { WidgetSnapshot.Upcoming(id: ModelRef.encode($0.persistentModelID), kind: .bill, name: $0.name, date: $0.nextDueDate,
                                           amount: $0.amount, currency: $0.currencyCode, symbol: $0.kind.symbol) }
        let expiries = ((try? context.fetch(FetchDescriptor<ExpiryItem>(predicate: #Predicate { !$0.isArchived }))) ?? [])
            .filter { $0.expiryDate >= startOfToday && $0.expiryDate < expiryHorizon }
            .map { WidgetSnapshot.Upcoming(id: ModelRef.encode($0.persistentModelID), kind: .expiry, name: $0.name, date: $0.expiryDate,
                                           amount: nil, currency: "", symbol: $0.kind.symbol) }

        return WidgetSnapshot(
            generatedAt: now, currency: LedgerSummary.baseCurrency, tasks: Array(tasks),
            monthStart: month.start, monthExpense: monthExpense, monthIncome: monthIncome,
            monthBudget: LedgerSummary.monthlyBudget(context: context), todayExpense: todayExpense,
            upcoming: Array((bills + expiries).sorted { $0.date < $1.date }.prefix(10)))
    }
}

extension WidgetSnapshot {
    /// Equal apart from when it was made.
    func sameContent(as other: WidgetSnapshot) -> Bool {
        var copy = other
        copy.generatedAt = generatedAt
        return copy == self && Calendar.current.isDate(generatedAt, inSameDayAs: other.generatedAt)
    }
}
