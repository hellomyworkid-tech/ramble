import Foundation
import SwiftData

/// Spending totals for Siri, Shortcuts and widgets, worked out as the app's screens do: expenses
/// in the base currency at each entry's own rate, and a category including its subcategories.
enum LedgerSummary {
    enum Period: String, CaseIterable {
        case today, thisWeek, thisMonth, lastMonth, thisYear

        var title: String {
            switch self {
            case .today: String(localized: "今天")
            case .thisWeek: String(localized: "本周")
            case .thisMonth: String(localized: "本月")
            case .lastMonth: String(localized: "上个月")
            case .thisYear: String(localized: "今年")
            }
        }
    }

    static func interval(_ period: Period, now: Date = .now, calendar: Calendar = .current) -> DateInterval {
        let component: Calendar.Component = switch period {
        case .today: .day
        case .thisWeek: .weekOfYear
        case .thisMonth, .lastMonth: .month
        case .thisYear: .year
        }
        let reference = period == .lastMonth ? calendar.date(byAdding: .month, value: -1, to: now) ?? now : now
        return calendar.dateInterval(of: component, for: reference) ?? DateInterval(start: now, duration: 0)
    }

    /// Expenses in the interval, optionally only one category (by name, as Siri passes it).
    static func expenses(in interval: DateInterval, categoryName: String? = nil, context: ModelContext) -> Decimal {
        let start = interval.start, end = interval.end
        let expense = EntryKind.expense.rawValue
        let descriptor = FetchDescriptor<LedgerEntry>(predicate: #Predicate {
            $0.date >= start && $0.date < end && $0.kindRaw == expense
        })
        let entries = (try? context.fetch(descriptor)) ?? []
        return entries
            .filter { entry in
                guard let categoryName else { return true }
                return entry.category?.name == categoryName || entry.category?.parent?.name == categoryName
            }
            .reduce(0) { $0 + $1.baseAmount }
    }

    /// The monthly budget: overall, or for one category.
    static func monthlyBudget(categoryName: String? = nil, context: ModelContext) -> Decimal? {
        let budgets = (try? context.fetch(FetchDescriptor<Budget>())) ?? []
        return budgets.first { $0.category?.name == categoryName }?.amount
    }

    static var baseCurrency: String {
        UserDefaults.standard.string(forKey: AppSettings.baseCurrencyKey) ?? AppSettings.defaultBaseCurrency
    }
}
