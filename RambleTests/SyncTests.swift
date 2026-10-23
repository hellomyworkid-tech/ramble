import Foundation
import SwiftData
import Testing
@testable import Ramble

@MainActor
struct CloudKitSchemaTests {
    /// CloudKit rejects unique constraints, required properties without defaults and relationships
    /// without inverses when the store opens; this catches a model change that would break syncing.
    @Test func theSchemaOpensWithCloudKit() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "cloudkit-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(at: URL(filePath: url.path + suffix)) }
        }
        let schema = Schema(AppSchema.models)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .private(SyncSettings.containerID))
        _ = try ModelContainer(for: schema, configurations: configuration)
    }
}

@MainActor
struct SyncDeduperTests {
    private let container = AppSchema.makeContainer(inMemory: true)

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "sync-\(UUID().uuidString)")!
    }

    /// This device seeds and notes its copies; then the other device's older copies arrive.
    private func twoDevices(_ defaults: UserDefaults) throws -> (context: ModelContext, theirs: [LedgerCategory], ours: [LedgerCategory]) {
        let context = container.mainContext
        SeedData.seedDefaultsIfNeeded(context)
        SyncDeduper.recordOwnSeeds(in: context, defaults: defaults)
        let ours = try context.fetch(FetchDescriptor<LedgerCategory>())
        let older = Date.now.addingTimeInterval(-86_400 * 30)
        var theirs: [LedgerCategory] = []
        for category in ours {
            let copy = LedgerCategory(name: category.name, kind: category.kind, symbol: category.symbol, colorHex: category.colorHex,
                                      sortOrder: category.sortOrder, seedKey: category.seedKey)
            copy.createdAt = older
            context.insert(copy)
            theirs.append(copy)
        }
        let accounts = try context.fetch(FetchDescriptor<Account>())
        for account in accounts {
            let copy = Account(name: account.name, kind: account.kind, currencyCode: account.currencyCode, sortOrder: account.sortOrder)
            copy.seedKey = account.seedKey
            copy.createdAt = older
            if account.kind == .creditCard { copy.creditLimit = 30_000 }
            context.insert(copy)
        }
        try context.save()
        return (context, theirs, ours)
    }

    @Test func ourCopiesMergeIntoTheOlderOnes() throws {
        let defaults = defaults()
        let (context, theirs, ours) = try twoDevices(defaults)
        let ourFood = try #require(ours.first { $0.seedKey == "food" })
        let lunch = LedgerEntry(kind: .expense, amount: 35, currencyCode: "CNY", note: "午餐")
        context.insert(lunch)
        lunch.category = ourFood
        let ourCash = try #require(try context.fetch(FetchDescriptor<Account>()).first { $0.seedKey == "cash" && $0.createdAt > .now.addingTimeInterval(-60) })
        lunch.account = ourCash
        let budget = Budget(amount: 800)
        context.insert(budget)
        budget.category = ourFood
        try context.save()

        let removed = SyncDeduper.run(in: context, defaults: defaults)
        #expect(removed == ours.count + 4)

        let categories = try context.fetch(FetchDescriptor<LedgerCategory>())
        #expect(categories.count == theirs.count)
        #expect(Set(categories.map(\.persistentModelID)) == Set(theirs.map(\.persistentModelID)))
        let theirFood = try #require(theirs.first { $0.seedKey == "food" })
        #expect(lunch.category === theirFood && budget.category === theirFood)
        let accounts = try context.fetch(FetchDescriptor<Account>())
        #expect(accounts.count == 4)
        #expect(lunch.account?.seedKey == "cash" && lunch.account !== ourCash)
        #expect(accounts.first { $0.kind == .creditCard }?.creditLimit == 30_000)
    }

    /// The other device removes its own copies; this one leaves them alone, even when they're newer.
    @Test func otherDevicesCopiesAreNeverDeletedHere() throws {
        let defaults = defaults()
        let context = container.mainContext
        SeedData.seedDefaultsIfNeeded(context)
        let ours = try context.fetch(FetchDescriptor<LedgerCategory>())
        for category in ours { category.createdAt = .now.addingTimeInterval(-86_400) }
        SyncDeduper.recordOwnSeeds(in: context, defaults: defaults)
        let newer = LedgerCategory(name: "餐饮", kind: .expense, symbol: "fork.knife", colorHex: "#D9480F", seedKey: "food")
        context.insert(newer)
        try context.save()

        #expect(SyncDeduper.run(in: context, defaults: defaults) == 0)
        #expect(try context.fetch(FetchDescriptor<LedgerCategory>()).count == ours.count + 1)
    }

    @Test func duplicateBudgetsKeepTheLatest() throws {
        let context = container.mainContext
        let older = Budget(amount: 5000)
        older.createdAt = .now.addingTimeInterval(-3600)
        context.insert(older)
        context.insert(Budget(amount: 6000))
        try context.save()
        #expect(SyncDeduper.run(in: context, defaults: defaults()) == 1)
        #expect(try context.fetch(FetchDescriptor<Budget>()).map(\.amount) == [6000])
    }

    @Test func accountsSeededBeforeKeysExistedGetThem() throws {
        let context = container.mainContext
        let cash = Account(name: "现金", kind: .cash)
        let mine = Account(name: "现金", kind: .eWallet)
        context.insert(cash)
        context.insert(mine)
        try context.save()
        SeedData.backfillAccountSeedKeys(context)
        #expect(cash.seedKey == "cash")
        #expect(mine.seedKey == nil)
    }
}
