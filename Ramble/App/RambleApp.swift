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
        // `-testLongNote`: enough entries in 装修记录 for its page to scroll.
        if arguments.contains("-testLongNote"),
           let note = ((try? container.mainContext.fetch(FetchDescriptor<Note>())) ?? []).first(where: { $0.title == "装修记录" }) {
            for number in 1...30 {
                note.append("第 \(number) 条记录\n写得长一点，这样每一条都占一些地方。", date: .now.addingTimeInterval(Double(number - 40) * 3600), in: container.mainContext)
            }
            try? container.mainContext.save()
        }
        if arguments.contains("-openAsk") { AppRouter.shared.ask(nil) }
        // A throwaway run: nothing shared earlier opens by itself in the middle of a test.
        if arguments.contains("-inMemoryStore") { ShareInbox.shared?.removeAll() }
        // `-testShare 这段话`: as if it had just come from the share sheet. `-testShareFile` does the same with a file.
        if let inbox = ShareInbox.shared, let draft = try? inbox.makeDraft() {
            if let index = arguments.firstIndex(of: "-testShare"), index + 1 < arguments.count {
                try? inbox.commit(draft, text: arguments[index + 1])
            } else if let index = arguments.firstIndex(of: "-testShareFile"), index + 1 < arguments.count {
                try? draft.addFile(Data(arguments[index + 1].utf8), named: "shared.txt")
                try? inbox.commit(draft, text: "")
            }
        }
        // Screenshots: a link opened from outside would stop at the system's 「在随口记中打开？」.
        if let index = arguments.firstIndex(of: "-openLink"), index + 1 < arguments.count,
           let link = URL(string: arguments[index + 1]) {
            AppRouter.shared.open(link)
        }
        // `-testReminder 交季度报告`: that to-do's reminder, a few seconds from now.
        if let index = arguments.firstIndex(of: "-testReminder"), index + 1 < arguments.count {
            let title = arguments[index + 1]
            let tasks = (try? container.mainContext.fetch(FetchDescriptor<TaskItem>())) ?? []
            if let task = tasks.first(where: { $0.title == title }) {
                let id = ModelRef.encode(task.persistentModelID)
                Task { await NotificationScheduler.shared.fireTestReminder(title: title, id: id) }
            }
        }
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
                SpotlightIndex.shared.setNeedsRefresh()
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
