import Foundation
import SwiftData

@Model
final class Account {
    var name: String = ""
    var kindRaw: String = AccountKind.cash.rawValue
    var currencyCode: String = "CNY"
    var initialBalance: Decimal = 0
    var creditLimit: Decimal?
    var statementDay: Int?
    var paymentDueDay: Int?
    var sortOrder: Int = 0
    var isArchived: Bool = false
    var createdAt: Date = Date.now
    /// Set on the accounts the app creates, so the copies each new device makes can be merged after syncing.
    var seedKey: String?

    @Relationship(deleteRule: .nullify, inverse: \LedgerEntry.account)
    var entries: [LedgerEntry]? = []
    @Relationship(deleteRule: .nullify, inverse: \LedgerEntry.toAccount)
    var incomingTransfers: [LedgerEntry]? = []
    @Relationship(deleteRule: .nullify, inverse: \Bill.account)
    var bills: [Bill]? = []
    @Relationship(deleteRule: .nullify, inverse: \Bill.creditAccount)
    var repaymentBills: [Bill]? = []
    @Relationship(deleteRule: .nullify, inverse: \Outstanding.account)
    var outstandings: [Outstanding]? = []

    init(name: String, kind: AccountKind, currencyCode: String = "CNY", initialBalance: Decimal = 0, sortOrder: Int = 0) {
        self.name = name
        self.kindRaw = kind.rawValue
        self.currencyCode = currencyCode
        self.initialBalance = initialBalance
        self.sortOrder = sortOrder
        self.createdAt = .now
    }

    var kind: AccountKind {
        get { AccountKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    /// Balance in the account's own currency. Entries recorded in another
    /// currency are converted through their base-currency rate.
    var balance: Decimal {
        var total = initialBalance
        for entry in entries ?? [] {
            let amount = entry.amount(in: currencyCode)
            switch entry.kind {
            case .income: total += amount
            case .expense, .transfer: total -= amount
            }
        }
        for entry in incomingTransfers ?? [] {
            total += entry.amount(in: currencyCode)
        }
        return total
    }
}

@Model
final class LedgerCategory {
    var name: String = ""
    var kindRaw: String = CategoryKind.expense.rawValue
    var symbol: String = "tag"
    var colorHex: String = "#6E6E73"
    var sortOrder: Int = 0
    /// Stable key for built-in categories, so seeding on two devices can be de-duplicated after sync.
    var seedKey: String?
    /// Which copy of a built-in category every device keeps: the oldest.
    var createdAt: Date = Date.now
    var parent: LedgerCategory?

    @Relationship(deleteRule: .cascade, inverse: \LedgerCategory.parent)
    var children: [LedgerCategory]? = []
    @Relationship(deleteRule: .nullify, inverse: \LedgerEntry.category)
    var entries: [LedgerEntry]? = []
    /// Deleted with the category: a budget left without one would count as the overall budget.
    @Relationship(deleteRule: .cascade, inverse: \Budget.category)
    var budgets: [Budget]? = []
    @Relationship(deleteRule: .nullify, inverse: \Bill.category)
    var bills: [Bill]? = []
    @Relationship(deleteRule: .nullify, inverse: \Outstanding.category)
    var outstandings: [Outstanding]? = []

    init(name: String, kind: CategoryKind, symbol: String, colorHex: String, sortOrder: Int = 0, seedKey: String? = nil) {
        self.name = name
        self.kindRaw = kind.rawValue
        self.symbol = symbol
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.seedKey = seedKey
        self.createdAt = .now
    }

    var kind: CategoryKind {
        get { CategoryKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }
}

@Model
final class LedgerEntry {
    var kindRaw: String = EntryKind.expense.rawValue
    /// Always positive; direction comes from `kind`.
    var amount: Decimal = 0
    var currencyCode: String = "CNY"
    /// 1 unit of `currencyCode` in the base currency at the time of recording.
    var rateToBase: Decimal = 1
    var date: Date = Date.now
    var note: String = ""
    var sourceRaw: String = EntrySource.manual.rawValue
    var createdAt: Date = Date.now

    var account: Account?
    var toAccount: Account?
    var category: LedgerCategory?
    var bill: Bill?
    /// The 应收 or 应付 this entry settled.
    var outstanding: Outstanding?
    @Relationship(deleteRule: .cascade, inverse: \Attachment.entry)
    var attachments: [Attachment]? = []

    init(kind: EntryKind, amount: Decimal, currencyCode: String, date: Date = .now, note: String = "", source: EntrySource = .manual) {
        self.kindRaw = kind.rawValue
        self.amount = amount
        self.currencyCode = currencyCode
        self.date = date
        self.note = note
        self.sourceRaw = source.rawValue
        self.createdAt = .now
    }

    var kind: EntryKind {
        get { EntryKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }

    var source: EntrySource {
        EntrySource(rawValue: sourceRaw) ?? .manual
    }

    var baseAmount: Decimal { amount * rateToBase }

    /// Converts through the base currency: this entry's stored rate in, today's rate out.
    func amount(in code: String) -> Decimal {
        if code == currencyCode { return amount }
        let base = UserDefaults.standard.string(forKey: AppSettings.baseCurrencyKey) ?? AppSettings.defaultBaseCurrency
        if code == base { return baseAmount }
        guard let rate = ExchangeRates.shared.rateToBase(code, base: base), rate > 0 else { return baseAmount }
        return (baseAmount / rate).rounded(scale: 2)
    }

    /// Stamps today's rate for a foreign-currency entry (1 when it is the base currency).
    func applyCurrentRate() {
        let base = UserDefaults.standard.string(forKey: AppSettings.baseCurrencyKey) ?? AppSettings.defaultBaseCurrency
        rateToBase = ExchangeRates.shared.rateToBase(currencyCode, base: base) ?? 1
    }

    /// The title shown in lists: note first, then category, then kind.
    var displayTitle: String {
        if !note.isEmpty { return note }
        if let category { return category.name }
        return String(localized: kind.title)
    }
}

/// A monthly budget in the base currency. A nil category is the overall budget.
@Model
final class Budget {
    var amount: Decimal = 0
    var createdAt: Date = Date.now
    var category: LedgerCategory?

    init(amount: Decimal) {
        self.amount = amount
        self.createdAt = .now
    }
}
