import CloudKit
import CoreData
import Foundation
import Observation
import OSLog
import SwiftData

/// Whether the library syncs through the person's own iCloud (CloudKit private database).
nonisolated enum SyncSettings {
    static let enabledKey = "sync.iCloud"
    static let containerID = "iCloud.com.zengji.suikouji"

    /// On unless turned off. Read once at launch: the store opens with or without CloudKit.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Unit tests and previews keep to a local store.
    static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

/// What the settings screen shows about syncing: the iCloud account, the last finished import and
/// export, and the last error, worth acting on, in plain words.
@Observable
final class SyncMonitor {
    static let shared = SyncMonitor()

    enum Account: Equatable {
        case checking, available, noAccount, restricted, temporarilyUnavailable, unknown
    }

    private(set) var account: Account = .checking
    private(set) var lastSync: Date?
    private(set) var isSyncing = false
    private(set) var lastError: String?
    /// Set when the store couldn't open with CloudKit and fell back to local only.
    var setupError: String?
    /// Whether this launch opened the store with CloudKit.
    var isActive = false

    private var observers: [NSObjectProtocol] = []
    private let log = Logger(subsystem: "com.zengji.suikouji", category: "sync")
    private static let lastSyncKey = "sync.lastSync"

    private init() {
        lastSync = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
    }

    /// Starts listening; `onImport` runs after each batch of changes arrives from other devices.
    func start(onImport: @escaping @MainActor () -> Void) {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
                                                                object: nil, queue: .main) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            let type = event.type, succeeded = event.succeeded, ended = event.endDate
            let message = event.error.map(Self.describe)
            MainActor.assumeIsolated {
                self?.record(type: type, succeeded: succeeded, ended: ended, error: message)
                if type == .import, ended != nil, succeeded { onImport() }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.refreshAccount() } }
        })
        Task { await refreshAccount() }
    }

    func refreshAccount() async {
        let status = (try? await CKContainer(identifier: SyncSettings.containerID).accountStatus()) ?? .couldNotDetermine
        account = switch status {
        case .available: .available
        case .noAccount: .noAccount
        case .restricted: .restricted
        case .temporarilyUnavailable: .temporarilyUnavailable
        default: .unknown
        }
    }

    private func record(type: NSPersistentCloudKitContainer.EventType, succeeded: Bool, ended: Date?, error: String?) {
        guard let ended else {
            if type != .setup { isSyncing = true }
            return
        }
        isSyncing = false
        if succeeded {
            if type != .setup {
                lastSync = ended
                UserDefaults.standard.set(ended, forKey: Self.lastSyncKey)
            }
            lastError = nil
        } else if let error {
            lastError = error
            log.error("sync \(type.rawValue) failed: \(error, privacy: .public)")
        }
    }

    /// CloudKit's errors in words the person can act on.
    nonisolated static func describe(_ error: Error) -> String {
        guard let ck = error as? CKError else { return error.localizedDescription }
        switch ck.code {
        case .quotaExceeded: return String(localized: "iCloud 空间已满，新内容暂时传不上去。清理 iCloud 空间或升级容量后会自动继续。")
        case .notAuthenticated: return String(localized: "这台设备没有登录 iCloud，或者在设置里关闭了随口记的 iCloud。")
        case .networkUnavailable, .networkFailure: return String(localized: "没有网络，联网后会自动同步。")
        case .serviceUnavailable, .requestRateLimited, .zoneBusy: return String(localized: "iCloud 暂时繁忙，稍后会自动重试。")
        case .partialFailure: return String(localized: "有部分内容没传上去，稍后会自动重试。")
        default: return ck.localizedDescription
        }
    }
}

/// Each new device seeds its own 「餐饮」「现金」 before the library arrives from iCloud, so after
/// syncing there are two of each. Every device agrees to keep the oldest copy (by a date that
/// syncs), and each device removes only the copies it made itself, after moving its records onto
/// the one kept. A device never deletes another's copy, so nothing is deleted from under records
/// that haven't arrived yet.
enum SyncDeduper {
    private static let ownedKey = "sync.ownedSeeds"
    private static let recordedKey = "sync.ownedSeedsRecorded"

    /// Notes which seeded categories and accounts this device made. Run once, right after seeding
    /// and before anything can arrive from iCloud.
    static func recordOwnSeeds(in context: ModelContext, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: recordedKey) else { return }
        let categories = (try? context.fetch(FetchDescriptor<LedgerCategory>(predicate: #Predicate { $0.seedKey != nil }))) ?? []
        let accounts = (try? context.fetch(FetchDescriptor<Account>(predicate: #Predicate { $0.seedKey != nil }))) ?? []
        let ids = categories.map { key(for: $0) } + accounts.map { key(for: $0) }
        defaults.set(ids, forKey: ownedKey)
        defaults.set(true, forKey: recordedKey)
    }

    @discardableResult
    static func run(in context: ModelContext, defaults: UserDefaults = .standard) -> Int {
        let owned = Set(defaults.stringArray(forKey: ownedKey) ?? [])
        var removed = 0
        removed += mergeCategories(context, owned: owned)
        removed += mergeAccounts(context, owned: owned)
        removed += mergeBudgets(context)
        if removed > 0 { try? context.save() }
        return removed
    }

    private static func isOwned(_ model: some PersistentModel, in owned: Set<String>) -> Bool {
        owned.contains(key(for: model))
    }

    /// The same text for the same record every time: an identifier's JSON keys come out in a
    /// different order from one encoding to the next unless sorted.
    static func key(for model: some PersistentModel) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(model.persistentModelID))?.base64EncodedString() ?? ""
    }

    private static func mergeCategories(_ context: ModelContext, owned: Set<String>) -> Int {
        let all = (try? context.fetch(FetchDescriptor<LedgerCategory>(predicate: #Predicate { $0.seedKey != nil }))) ?? []
        var removed = 0
        for (_, copies) in Dictionary(grouping: all, by: { "\($0.kindRaw)|\($0.seedKey ?? "")" }) where copies.count > 1 {
            let ordered = copies.sorted { ($0.createdAt, $0.name) < ($1.createdAt, $1.name) }
            let keeper = ordered[0]
            for duplicate in ordered.dropFirst() where isOwned(duplicate, in: owned) {
                for entry in duplicate.entries ?? [] { entry.category = keeper }
                for budget in duplicate.budgets ?? [] { budget.category = keeper }
                for bill in duplicate.bills ?? [] { bill.category = keeper }
                for item in duplicate.outstandings ?? [] { item.category = keeper }
                for child in duplicate.children ?? [] { child.parent = keeper }
                context.delete(duplicate)
                removed += 1
            }
        }
        return removed
    }

    private static func mergeAccounts(_ context: ModelContext, owned: Set<String>) -> Int {
        let all = (try? context.fetch(FetchDescriptor<Account>(predicate: #Predicate { $0.seedKey != nil }))) ?? []
        var removed = 0
        for (_, copies) in Dictionary(grouping: all, by: { $0.seedKey ?? "" }) where copies.count > 1 {
            let ordered = copies.sorted { ($0.createdAt, $0.name) < ($1.createdAt, $1.name) }
            let keeper = ordered[0]
            for duplicate in ordered.dropFirst() where isOwned(duplicate, in: owned) {
                for entry in duplicate.entries ?? [] { entry.account = keeper }
                for entry in duplicate.incomingTransfers ?? [] { entry.toAccount = keeper }
                for bill in duplicate.bills ?? [] { bill.account = keeper }
                for bill in duplicate.repaymentBills ?? [] { bill.creditAccount = keeper }
                for item in duplicate.outstandings ?? [] { item.account = keeper }
                // A balance or card details set on this copy aren't lost.
                if keeper.initialBalance == 0 { keeper.initialBalance = duplicate.initialBalance }
                if keeper.creditLimit == nil { keeper.creditLimit = duplicate.creditLimit }
                if keeper.statementDay == nil { keeper.statementDay = duplicate.statementDay }
                if keeper.paymentDueDay == nil { keeper.paymentDueDay = duplicate.paymentDueDay }
                context.delete(duplicate)
                removed += 1
            }
        }
        return removed
    }

    /// Two budgets for one category (or two overall ones) once categories are merged: the most
    /// recently set wins. Nothing points at a budget, so removing one loses nothing else.
    private static func mergeBudgets(_ context: ModelContext) -> Int {
        let all = (try? context.fetch(FetchDescriptor<Budget>())) ?? []
        var removed = 0
        for (_, copies) in Dictionary(grouping: all, by: { $0.category?.persistentModelID }) where copies.count > 1 {
            for duplicate in copies.sorted(by: { ($0.createdAt, $0.amount) > ($1.createdAt, $1.amount) }).dropFirst() {
                context.delete(duplicate)
                removed += 1
            }
        }
        return removed
    }
}
