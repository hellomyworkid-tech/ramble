import Foundation
import SwiftData

/// Money coming back for something bought: 「运动鞋退款 268」. Whichever model read it, it arrives as
/// income or spending, so the app sorts it out itself, as with `OutstandingCues`.
enum RefundCues {
    static func isRefund(_ text: String) -> Bool {
        // 退税 is income in its own right.
        guard text.firstMatch(of: #/退税|tax refund/#.ignoresCase()) == nil else { return false }
        return text.firstMatch(of: #/退款|退钱|退货|退票|退了|退回|退给我|refund/#.ignoresCase()) != nil
    }

    /// Spending from the last six months that still has something left to refund, newest first.
    static func candidates(in context: ModelContext, now: Date = .now) -> [LedgerEntry] {
        let since = Calendar.current.date(byAdding: .month, value: -6, to: now) ?? now
        let expense = EntryKind.expense.rawValue
        var descriptor = FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.date >= since && $0.kindRaw == expense },
                                                      sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 200
        return ((try? context.fetch(descriptor)) ?? []).filter { $0.netAmount > 0 }
    }

    /// The spending it most likely gives back: by what it was, then by amount. Nil rather than a
    /// guess when neither says, so the person picks.
    static func original(of title: String, amount: Decimal?, among expenses: [LedgerEntry]) -> LedgerEntry? {
        let sameAmount = { (entry: LedgerEntry) in amount == entry.amount || amount == entry.netAmount }
        var what = title.trimmed
        for word in ["退款", "退钱", "退货", "退票", "退了", "退回", "退给我", "的", "已经", "已", "了"] {
            what = what.replacingOccurrences(of: word, with: "")
        }
        what = what.trimmed
        if !what.isEmpty {
            let named = expenses.filter { entry in
                let note = entry.note.trimmed
                return !note.isEmpty && (note.localizedCaseInsensitiveContains(what) || what.localizedCaseInsensitiveContains(note))
            }
            if let match = named.first(where: sameAmount) ?? named.first { return match }
        }
        return amount == nil ? nil : expenses.first(where: sameAmount)
    }
}
