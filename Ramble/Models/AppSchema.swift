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
        Project.self,
        RecurringEntry.self,
    ]

    /// The one container for the app, Siri and Shortcuts (which run in the app's process). It
    /// syncs through the person's own iCloud unless they turned that off; tests stay local. An
    /// empty stand-in while the real library won't open: see `LibraryState`.
    static var shared: ModelContainer { LibraryState.shared.container }

    /// For Siri and Shortcuts, which can run with nobody looking at the recovery page: a record
    /// saved into the stand-in would be gone by the next launch.
    static func liveContext() throws -> ModelContext {
        guard LibraryState.shared.failure == nil else { throw LibraryError.unavailable }
        return shared.mainContext
    }

    /// The library on this device, mirrored to the CloudKit private database when `sync` is on. If
    /// CloudKit can't be set up the same store opens local only, rather than the app failing to
    /// start. Throws when the store itself won't open.
    static func openLibrary(sync: Bool, at url: URL? = nil) throws -> ModelContainer {
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
        let configuration = url.map { ModelConfiguration(schema: schema, url: $0, cloudKitDatabase: .none) }
            ?? ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: configuration)
    }

    /// Where the library's files are. SwiftData decides: in an app that belongs to an app group,
    /// that group's folder rather than the app's own.
    static var libraryFolder: URL {
        ModelConfiguration(schema: Schema(models), cloudKitDatabase: .none).url.deletingLastPathComponent()
    }

    /// An empty library in memory: tests, throwaway runs, and the stand-in for one that won't open.
    static func inMemoryContainer() -> ModelContainer {
        let schema = Schema(models)
        do {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        } catch {
            fatalError("Could not create an in-memory ModelContainer: \(error)")
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
