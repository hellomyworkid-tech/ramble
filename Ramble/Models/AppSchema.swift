import CoreData
import Foundation
import SwiftData

enum AppSchema {
    static let models: [any PersistentModel.Type] = [
        TaskItem.self,
        Subtask.self,
        Account.self,
        LedgerCategory.self,
        LedgerEntry.self,
        Budget.self,
        Bill.self,
        Outstanding.self,
        ExpiryItem.self,
        Attachment.self,
        Note.self,
        NoteEntry.self,
    ]

    /// The one container for the app, Siri and Shortcuts (which run in the app's process). It
    /// syncs through the person's own iCloud unless they turned that off; tests stay local.
    static let shared: ModelContainer = {
        let inMemory = ProcessInfo.processInfo.arguments.contains("-inMemoryStore")
        let sync = SyncSettings.isEnabled && !inMemory && !SyncSettings.isTesting
        return makeContainer(inMemory: inMemory, sync: sync)
    }()

    /// A store on this device, mirrored to the CloudKit private database when `sync` is on. If
    /// CloudKit can't be set up the same store opens local only, rather than the app failing to start.
    static func makeContainer(inMemory: Bool = false, sync: Bool = false) -> ModelContainer {
        let schema = Schema(models)
        if sync {
            let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .private(SyncSettings.containerID))
            do {
                let container = try ModelContainer(for: schema, configurations: configuration)
                MainActor.assumeIsolated { SyncMonitor.shared.isActive = true }
                return container
            } catch {
                MainActor.assumeIsolated { SyncMonitor.shared.setupError = error.localizedDescription }
            }
        }
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    #if DEBUG
    /// Creates every record type in the CloudKit development schema, so "Deploy Schema Changes"
    /// carries all of them to production. SwiftData only adds a type the first time a record of it
    /// syncs, and a type missing in production makes those records fail to sync for everyone.
    /// Runs against a throwaway store (Apple's recipe for SwiftData); launch a debug build with
    /// `-initializeCloudKitSchema`.
    static func initializeCloudKitSchema() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "cloudkit-schema.store")
        let description = NSPersistentStoreDescription(url: url)
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: SyncSettings.containerID)
        description.shouldAddStoreAsynchronously = false
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: models) else { return }
        try autoreleasepool {
            let container = NSPersistentCloudKitContainer(name: "Ramble", managedObjectModel: model)
            container.persistentStoreDescriptions = [description]
            var loadError: Error?
            container.loadPersistentStores { _, error in loadError = error }
            if let loadError { throw loadError }
            try container.initializeCloudKitSchema()
            if let store = container.persistentStoreCoordinator.persistentStores.first {
                try container.persistentStoreCoordinator.remove(store)
            }
        }
        try? FileManager.default.removeItem(at: url)
    }
    #endif
}

enum AppSettings {
    static let baseCurrencyKey = "baseCurrency"
    static let defaultBaseCurrency = "CNY"

    /// Fixes the base currency once, the first time the app runs: the phone region's currency on a
    /// new install (CNY in China, USD in the US), CNY for a library that already has records in it.
    /// Stored rather than read from the region each time, so totals never change currency by themselves.
    static func storeBaseCurrencyIfNeeded(isNewLibrary: Bool, defaults: UserDefaults = .standard,
                                          locale: Locale = .current) {
        guard defaults.string(forKey: baseCurrencyKey) == nil else { return }
        let regional = locale.currency?.identifier
        let code = isNewLibrary ? (regional.flatMap { Locale.commonISOCurrencyCodes.contains($0) ? $0 : nil } ?? defaultBaseCurrency)
                                : defaultBaseCurrency
        defaults.set(code, forKey: baseCurrencyKey)
    }
    static let commonCurrencies = ["CNY", "USD", "HKD", "EUR", "GBP", "JPY", "TWD", "SGD", "AUD", "CAD", "KRW", "MOP"]
}
