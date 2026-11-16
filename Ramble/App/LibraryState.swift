import Foundation
import Observation
import SwiftData

/// The library on this device, or why it wouldn't open. A damaged store, or a phone out of space,
/// would otherwise crash the app at every launch with no way to reach the records.
@Observable
final class LibraryState {
    static let shared = LibraryState()

    private(set) var container: ModelContainer
    /// Why the library wouldn't open. While this is set `LibraryRecoveryView` shows instead of the
    /// app, `container` is an empty stand-in in memory, and nothing reads or changes the real files
    /// (an automatic backup of the stand-in would push out the good ones).
    private(set) var failure: String?

    private init() {
        do {
            container = try Self.open()
        } catch {
            container = AppSchema.inMemoryContainer()
            failure = String(describing: error)
        }
    }

    private static func open() throws -> ModelContainer {
        let arguments = ProcessInfo.processInfo.arguments
        #if DEBUG
        if arguments.contains("-testBrokenLibrary"), !startedOver { throw LibraryError.unavailable }
        #endif
        if arguments.contains("-inMemoryStore") { return AppSchema.inMemoryContainer() }
        return try AppSchema.openLibrary(sync: SyncSettings.isEnabled && !SyncSettings.isTesting)
    }

    #if DEBUG
    /// `-testBrokenLibrary`: the files "open" again only once they've been moved aside.
    private static var startedOver = false
    #endif

    /// The same files again: a phone that was out of space may have room now.
    func retry() {
        do {
            container = try Self.open()
            finish()
        } catch {
            failure = String(describing: error)
        }
    }

    /// Moves the files that won't open to where the person can still get at them, and opens a new
    /// library, with `backup` in it if there is one. Says how the backup went; `finish` then goes on
    /// to the app. A backup goes in with sync off: the records in iCloud would come back beside it.
    func startOver(restoring backup: PendingRestore? = nil) throws -> String? {
        try LibraryFiles.moveAside()
        #if DEBUG
        Self.startedOver = true
        #endif
        let turnedOffSync = backup != nil && SyncSettings.isEnabled
        if turnedOffSync { UserDefaults.standard.set(false, forKey: SyncSettings.enabledKey) }
        SyncDeduper.forgetOwnSeeds()
        container = try Self.open()
        guard let backup else { return nil }
        let outcome = backup.perform(in: container.mainContext)
        return turnedOffSync ? outcome + String(localized: "iCloud 同步已关闭，需要时可以在设置里重新打开；打开后两边的记录会合并，可能有重复。") : outcome
    }

    /// On to the app.
    func finish() {
        AppStartup.run(container)
        failure = nil
    }
}

enum LibraryError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        String(localized: "随口记现在打不开资料库，请打开 App 看看。")
    }
}

/// The library's files: the store, its journal, and the photos SwiftData keeps beside it, among
/// whatever else is in that folder under other names.
enum LibraryFiles {
    static func items(in folder: URL = AppSchema.libraryFolder) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix("default") || $0.hasPrefix(".default") }.map { folder.appending(path: $0) }
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    /// Into a dated folder in Documents, which shows in 文件 › 我的 iPhone › 随口记. Nothing here
    /// deletes them: they may be all there is, and that's for the person to decide.
    @discardableResult
    static func moveAside(from folder: URL = AppSchema.libraryFolder, to documents: URL = .documentsDirectory,
                          now: Date = .now) throws -> URL? {
        let items = items(in: folder)
        guard !items.isEmpty else { return nil }
        let destination = documents.appending(path: String(localized: "打不开的资料库 \(stampFormatter.string(from: now))"),
                                               directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in items {
            try FileManager.default.moveItem(at: item, to: destination.appending(path: item.lastPathComponent))
        }
        return destination
    }

    /// A zip of them, to save somewhere safe before doing anything else. Nil when there are none.
    static func archive(from folder: URL = AppSchema.libraryFolder, now: Date = .now) async throws -> URL? {
        let items = items(in: folder)
        guard !items.isEmpty else { return nil }
        let work = URL.temporaryDirectory.appending(path: "library-\(UUID().uuidString)", directoryHint: .isDirectory)
        let copies = work.appending(path: "ramble-library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        for item in items {
            try FileManager.default.copyItem(at: item, to: copies.appending(path: item.lastPathComponent))
        }
        let zip = work.appending(path: String(localized: "随口记原文件 \(stampFormatter.string(from: now)).zip"))
        try await BackupFiles.zip(copies, to: zip)
        try? FileManager.default.removeItem(at: copies)
        return zip
    }
}
