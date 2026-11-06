import Foundation
import SwiftData

/// An amount the way Shortcuts hands it over: 35.00, ¥35.00, HK$1,280.50, 88.00 HKD, 9,99 €.
nonisolated struct PaymentAmount: Equatable {
    var value: Decimal
    var currency: String

    /// Nil unless it's an amount above zero: a refund isn't a payment.
    init?(_ text: String, baseCurrency: String) {
        guard !text.contains("-"), !text.contains("−"),
              let match = text.firstMatch(of: #/[0-9](?:[0-9.,'\s]*[0-9])?/#) else { return nil }
        var digits = match.0.filter { !$0.isWhitespace && $0 != "'" }
        // The last separator is the decimal point if one or two digits follow it (35.5, 9,99);
        // otherwise it only groups thousands (1,280, 1.280).
        if let separator = digits.lastIndex(where: { $0 == "." || $0 == "," }) {
            let fraction = digits[digits.index(after: separator)...]
            let whole = digits[..<separator].filter(\.isNumber)
            digits = fraction.count <= 2 ? whole + "." + fraction : whole + fraction
        }
        guard let value = Decimal(string: String(digits), locale: Locale(identifier: "en_US_POSIX")), value > 0 else { return nil }
        self.value = value
        let before = String(text[..<match.range.lowerBound]), after = String(text[match.range.upperBound...])
        let sign = (before + after).trimmed.uppercased()
        currency = Self.currency(for: sign, baseCurrency: baseCurrency)
    }

    private static let signs = ["CN¥": "CNY", "RMB": "CNY", "元": "CNY", "JP¥": "JPY", "円": "JPY", "HK$": "HKD", "US$": "USD",
                                "NT$": "TWD", "MOP$": "MOP", "S$": "SGD", "SG$": "SGD", "A$": "AUD", "AU$": "AUD", "C$": "CAD",
                                "CA$": "CAD", "NZ$": "NZD", "€": "EUR", "£": "GBP", "₩": "KRW", "฿": "THB", "RM": "MYR"]
    private static let dollars: Set = ["USD", "HKD", "TWD", "SGD", "AUD", "CAD", "NZD"]

    /// A sign several currencies share means the person's own, when theirs is one of them.
    private static func currency(for sign: String, baseCurrency: String) -> String {
        switch sign {
        case "": baseCurrency
        case "¥", "￥": baseCurrency == "JPY" ? "JPY" : "CNY"
        case "$": dollars.contains(baseCurrency) ? baseCurrency : "USD"
        default: signs[sign] ?? (Locale.commonISOCurrencyCodes.contains(sign) ? sign : baseCurrency)
        }
    }
}

/// A payment recorded with nothing asked: Apple Pay automations run it without anyone looking.
enum PaymentEntry {
    /// The category and account come from the last time at this merchant, so correcting one
    /// entry settles it for next time. A merchant seen for the first time goes by its name.
    static func record(_ amount: PaymentAmount, merchant: String, card: String, in context: ModelContext, now: Date = .now) throws -> LedgerEntry {
        let name = merchant.trimmed
        let earlier = lastEntry(at: name, in: context)
        let categories = (try? context.fetch(FetchDescriptor<LedgerCategory>())) ?? []
        let accounts = (try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []

        let entry = LedgerEntry(kind: .expense, amount: amount.value, currencyCode: amount.currency, date: now, note: name)
        context.insert(entry)
        entry.applyCurrentRate()
        entry.category = earlier?.category ?? guessedCategory(for: name, among: categories)
        entry.account = DraftParsing.bestMatch(card, in: accounts.filter { !$0.isArchived }, name: \.name) ?? earlier?.account
        try context.save()
        return entry
    }

    private static func lastEntry(at merchant: String, in context: ModelContext) -> LedgerEntry? {
        guard !merchant.isEmpty else { return nil }
        let expense = EntryKind.expense.rawValue
        var descriptor = FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.note == merchant && $0.kindRaw == expense },
                                                      sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private static func guessedCategory(for merchant: String, among categories: [LedgerCategory]) -> LedgerCategory? {
        let expenses = categories.filter { $0.kind == .expense }
        let key = LedgerCSV.guessedSeedKey(for: merchant, kind: .expense) ?? "other-expense"
        return expenses.first { $0.seedKey == key } ?? expenses.first { $0.seedKey == "other-expense" }
    }
}
