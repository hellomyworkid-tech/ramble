import SwiftData
import SwiftUI

@main
struct RambleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    let container: ModelContainer

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        container = AppSchema.shared
        let isNewLibrary = ((try? container.mainContext.fetchCount(FetchDescriptor<LedgerCategory>())) ?? 0) == 0
        AppSettings.storeBaseCurrencyIfNeeded(isNewLibrary: isNewLibrary)
        SeedData.seedDefaultsIfNeeded(container.mainContext)
        SeedData.backfillAccountSeedKeys(container.mainContext)
        // Before anything arrives from iCloud: which built-in categories and accounts this device made.
        SyncDeduper.recordOwnSeeds(in: container.mainContext)
        LegacyWhisperFiles.migrateSetting()
        #if DEBUG
        if arguments.contains("-initializeCloudKitSchema") {
            do {
                try AppSchema.initializeCloudKitSchema()
                print("CloudKit schema initialized")
            } catch {
                print("CloudKit schema failed: \(error)")
            }
        }
        if arguments.contains("-sampleData") {
            SeedData.deleteAll(container.mainContext)
            SeedData.loadSampleData(container.mainContext)
        }
        // App Store screenshots: `-startTab ledger` opens on that tab.
        if let index = arguments.firstIndex(of: "-startTab"), index + 1 < arguments.count,
           let tab = AppTab(rawValue: arguments[index + 1]) {
            AppRouter.shared.tab = tab
        }
        if arguments.contains("-openAsk") { AppRouter.shared.ask(nil) }
        if let index = arguments.firstIndex(of: "-openNote"), index + 1 < arguments.count {
            let title = arguments[index + 1]
            let notes = (try? container.mainContext.fetch(FetchDescriptor<Note>())) ?? []
            if let note = notes.first(where: { $0.title == title }) { AppRouter.shared.open(note) }
        }
        #endif
        NotificationScheduler.shared.configure(container: container)
        if SyncMonitor.shared.isActive {
            let context = container.mainContext
            SyncDeduper.run(in: context)
            // Changes from other devices: merge duplicate defaults, re-plan reminders, refresh widgets.
            SyncMonitor.shared.start {
                SyncDeduper.run(in: context)
                NotificationScheduler.shared.setNeedsReschedule()
                WidgetBridge.setNeedsRefresh()
            }
        }
        // Reconnect to model downloads that kept running while the app was closed.
        BackgroundDownloads.shared.resume()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .refreshesOrientationOnResize()
        }
        .modelContainer(container)
        .backgroundTask(.appRefresh(NotificationScheduler.refreshTaskID)) {
            // Also brings widget completions in and rolls the widgets' "today" over.
            await MainActor.run {
                let context = AppSchema.shared.mainContext
                WidgetBridge.applyPendingCompletions(context: context)
                WidgetBridge.refresh(context: context)
            }
            await NotificationScheduler.shared.reschedule()
            await NotificationScheduler.scheduleBackgroundRefresh()
        }
        // iOS wakes the app when background model downloads finish, so files can be put in place.
        .backgroundTask(.urlSession(BackgroundDownloads.identifier)) {
            await BackgroundDownloads.shared.handleBackgroundEvents()
        }
    }
}
