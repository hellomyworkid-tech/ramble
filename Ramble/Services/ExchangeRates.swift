import Foundation
import Observation
import SwiftData

/// One day's rates against a base currency.
nonisolated struct RateTable: Codable, Equatable {
    var base: String
    /// Units of each currency per 1 unit of `base`.
    var rates: [String: Double]
    /// When the provider last updated these rates.
    var updatedAt: Date
    /// When this device fetched them.
    var fetchedAt: Date

    /// 1 unit of `code` expressed in the base currency.
    func rateToBase(_ code: String) -> Decimal? {
        if code == base { return 1 }
        guard let perBase = rates[code], perBase > 0 else { return nil }
        return Decimal(1 / perBase).rounded(scale: 6)
    }
}

/// Daily exchange rates from ExchangeRate-API's open endpoint (no key; attribution required).
/// Cached on the device, so conversion keeps working offline with the last rates.
@Observable
final class ExchangeRates {
    static let shared = ExchangeRates()
    static let attributionURL = URL(string: "https://www.exchangerate-api.com")!
    static let storageKey = "fx.rateTable"
    /// The provider refreshes once a day; checking twice a day is plenty.
    static let maxAge: TimeInterval = 12 * 3600

    private(set) var table: RateTable?
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private let defaults: UserDefaults
    private let session: URLSession

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        table = JSONStore.decode(RateTable.self, from: defaults.data(forKey: Self.storageKey))
    }

    /// 1 unit of `code` in `base`, from the cached table. Nil when unknown.
    func rateToBase(_ code: String, base: String) -> Decimal? {
        if code == base { return 1 }
        guard let table, table.base == base else { return nil }
        return table.rateToBase(code)
    }

    func refreshIfNeeded(base: String, now: Date = .now) async {
        if let table, table.base == base, now.timeIntervalSince(table.fetchedAt) < Self.maxAge { return }
        await refresh(base: base, now: now)
    }

    func refresh(base: String, now: Date = .now) async {
        guard !isRefreshing, let url = URL(string: "https://open.er-api.com/v6/latest/\(base)") else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let fresh = try Self.parse(data, fetchedAt: now)
            table = fresh
            lastError = nil
            defaults.set(JSONStore.encode(fresh), forKey: Self.storageKey)
        } catch {
            lastError = error.localizedDescription
        }
    }

    nonisolated static func parse(_ data: Data, fetchedAt: Date) throws -> RateTable {
        struct Payload: Decodable {
            let result: String
            let base_code: String
            let rates: [String: Double]
            let time_last_update_unix: TimeInterval
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.result == "success" else { throw URLError(.cannotParseResponse) }
        return RateTable(base: payload.base_code, rates: payload.rates,
                         updatedAt: Date(timeIntervalSince1970: payload.time_last_update_unix), fetchedAt: fetchedAt)
    }

    /// After the base currency changes, every stored rate points at the old base.
    /// Re-derive them from the current table; entries in an unknown currency keep theirs.
    func recalculateEntries(in context: ModelContext, base: String) {
        let entries = (try? context.fetch(FetchDescriptor<LedgerEntry>())) ?? []
        for entry in entries {
            if let rate = rateToBase(entry.currencyCode, base: base) {
                entry.rateToBase = rate
            }
        }
        try? context.save()
    }
}

extension Decimal {
    nonisolated func rounded(scale: Int) -> Decimal {
        var source = self
        var result = Decimal()
        NSDecimalRound(&result, &source, scale, .plain)
        return result
    }
}
