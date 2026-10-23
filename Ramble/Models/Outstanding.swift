import Foundation
import SwiftData

nonisolated enum OutstandingDirection: String, CaseIterable, Identifiable, Codable {
    /// Someone owes the person: 应收未收.
    case receivable
    /// The person owes someone: 应付未付.
    case payable

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .receivable: "应收"
        case .payable: "应付"
        }
    }

    /// What settling it records.
    var entryKind: EntryKind {
        self == .receivable ? .income : .expense
    }

    var categoryKind: CategoryKind {
        self == .receivable ? .income : .expense
    }

    /// The button that settles it: 「收到了」 or 「付了」.
    var settleTitle: LocalizedStringResource {
        switch self {
        case .receivable: "收到了"
        case .payable: "付了"
        }
    }
}

/// Money someone owes the person (应收) or the person owes someone (应付) that hasn't moved
/// yet. It stays out of every total until it's settled: settling, in full or in part, records
/// the income or expense in the ledger on the day it happens.
@Model
final class Outstanding {
    var directionRaw: String = OutstandingDirection.receivable.rawValue
    var title: String = ""
    /// Who pays or gets paid: 张三, 甲方, 装修师傅.
    var counterparty: String = ""
    /// The whole amount, before anything was settled.
    var amount: Decimal = 0
    var currencyCode: String = "CNY"
    /// When the money is expected, if anyone said.
    var dueDate: Date?
    var note: String = ""
    var createdAt: Date = Date.now

    /// What the income or expense is filed under when it's settled.
    var category: LedgerCategory?
    /// The account it comes into or goes out of.
    var account: Account?
    /// The ledger entries that settled it. Deleting one puts that much back to outstanding.
    @Relationship(deleteRule: .nullify, inverse: \LedgerEntry.outstanding)
    var settlements: [LedgerEntry]? = []

    init(direction: OutstandingDirection, title: String, counterparty: String = "", amount: Decimal,
         currencyCode: String = "CNY", dueDate: Date? = nil) {
        self.directionRaw = direction.rawValue
        self.title = title
        self.counterparty = counterparty
        self.amount = amount
        self.currencyCode = currencyCode
        self.dueDate = dueDate
        self.createdAt = .now
    }

    var direction: OutstandingDirection {
        get { OutstandingDirection(rawValue: directionRaw) ?? .receivable }
        set { directionRaw = newValue.rawValue }
    }

    /// Received or paid so far.
    var settledAmount: Decimal {
        (settlements ?? []).reduce(0) { $0 + $1.amount(in: currencyCode) }
    }

    var remaining: Decimal {
        max(0, amount - settledAmount)
    }

    var isSettled: Bool { remaining <= 0 }

    /// The latest settlement, for 「已结清」.
    var settledAt: Date? {
        (settlements ?? []).map(\.date).max()
    }

    func isOverdue(now: Date = .now) -> Bool {
        guard let dueDate, !isSettled else { return false }
        return dueDate < Calendar.current.startOfDay(for: now)
    }

    /// 「项目尾款 · 张三」, the note on the entries it records.
    var displayTitle: String {
        let name = title.trimmingCharacters(in: .whitespaces)
        let who = counterparty.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return who }
        return who.isEmpty || name.contains(who) ? name : "\(name) · \(who)"
    }

    /// Records the money as income or expense and counts it against what's owed.
    @discardableResult
    func settle(amount paid: Decimal, on date: Date, account chosen: Account?, in context: ModelContext) -> LedgerEntry {
        let entry = LedgerEntry(kind: direction.entryKind, amount: paid, currencyCode: currencyCode, date: date,
                                note: displayTitle, source: .outstanding)
        context.insert(entry)
        entry.applyCurrentRate()
        entry.account = chosen ?? account
        entry.category = category
        entry.outstanding = self
        return entry
    }
}
