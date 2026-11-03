import CryptoKit
import Foundation
import SwiftData
import UIKit

/// A backup a day, kept in the app's folder in iCloud Drive (on the phone when iCloud Drive is
/// off). Sync carries a mistake, such as a deletion, to every device; a backup from before it
/// doesn't change. The newest 7 are kept, and a photo is stored once however many of them
/// mention it.
@Observable
final class AutoBackup {
    static let shared = AutoBackup()

    static let enabledKey = "backup.auto.enabled"
    static let includesAttachmentsKey = "backup.includesAttachments"
    private static let lastKey = "backup.auto.last"
    private static let fingerprintKey = "backup.auto.fingerprint"
    static let keep = 7

    private(set) var isRunning = false
    private(set) var lastBackup: Date?
    private(set) var lastError: String?

    init() {
        lastBackup = UserDefaults.standard.object(forKey: Self.lastKey) as? Date
    }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// iCloud Drive › 随口记 when iCloud Drive is on for the app, otherwise 文件 › 我的 iPhone › 随口记.
    static func folder() async -> (url: URL, isICloud: Bool) {
        let containerID = SyncSettings.containerID
        return await Task.detached(priority: .utility) {
            // Can take a moment the first time, so never on the main thread.
            if let container = FileManager.default.url(forUbiquityContainerIdentifier: containerID) {
                return (container.appending(path: "Documents", directoryHint: .isDirectory), true)
            }
            return (URL.documentsDirectory, false)
        }.value
    }

    /// The first time the app comes to the front each day.
    func runIfDue(context: ModelContext, now: Date = .now) {
        guard isEnabled, !isRunning else { return }
        if let lastBackup, now.timeIntervalSince(lastBackup) < 20 * 3600 { return }
        Task { await run(context: context, now: now) }
    }

    /// Backs up now. Without `force`, nothing is written when nothing changed since the last one.
    func run(context: ModelContext, now: Date = .now, force: Bool = false) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        // A backup started just before the app goes to the background gets to finish.
        let background = UIApplication.shared.beginBackgroundTask(withName: "backup")
        defer { UIApplication.shared.endBackgroundTask(background) }
        do {
            let includesAttachments = UserDefaults.standard.object(forKey: Self.includesAttachmentsKey) as? Bool ?? true
            let fingerprint = try Self.fingerprint(of: context, includesAttachments: includesAttachments)
            if !force, fingerprint == UserDefaults.standard.string(forKey: Self.fingerprintKey) {
                markDone(now)
                return
            }
            let folder = await Self.folder().url
            try await BackupFiles.createDirectory(folder)
            try await Backup.write(from: context, includeAttachments: includesAttachments, to: folder,
                                   name: Self.name(for: now), now: now)
            await Self.prune(folder, keep: Self.keep)
            UserDefaults.standard.set(fingerprint, forKey: Self.fingerprintKey)
            markDone(now)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func markDone(_ now: Date) {
        lastBackup = now
        UserDefaults.standard.set(now, forKey: Self.lastKey)
    }

    /// Changes whenever a record or attachment does; not the date the backup is made.
    private static func fingerprint(of context: ModelContext, includesAttachments: Bool) throws -> String {
        var data = try Backup.encoder().encode(Backup.make(from: context, includeAttachments: false, now: .distantPast))
        if includesAttachments {
            let keys = try context.fetch(FetchDescriptor<Attachment>()).map(Backup.attachmentKey).sorted()
            data.append(Data(keys.joined(separator: ",").utf8))
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Saved backups

    /// One automatic backup in the folder.
    struct Saved: Identifiable, Hashable {
        let url: URL
        let date: Date
        var id: URL { url }
    }

    /// 「自动备份 2026-11-03 09.15.json」: readable in Files, sortable, and recognisable in any
    /// language by the stamp at the end.
    static func name(for date: Date) -> String {
        String(localized: "自动备份 \(stampFormatter.string(from: date))")
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter
    }()

    /// The automatic backups in `folder`, newest first, including ones still only in iCloud.
    static func saved(in folder: URL) -> [Saved] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let stamp = /(\d{4}-\d{2}-\d{2} \d{2}\.\d{2})\.json$/
        return names.compactMap { raw -> Saved? in
            // Not downloaded yet: iCloud leaves a placeholder named ".<name>.icloud".
            let name = raw.hasPrefix(".") && raw.hasSuffix(".icloud") ? String(raw.dropFirst().dropLast(".icloud".count)) : raw
            guard let match = name.firstMatch(of: stamp), let date = stampFormatter.date(from: String(match.1)) else { return nil }
            return Saved(url: folder.appending(path: name), date: date)
        }
        .sorted { $0.date > $1.date }
    }

    /// Keeps the newest `keep` automatic backups, then removes the photos and files none of them
    /// mentions. Leaves anything else in the folder alone, and keeps every attachment when a
    /// backup it would need to read is still only in iCloud.
    static func prune(_ folder: URL, keep: Int) async {
        let all = saved(in: folder)
        for old in all.dropFirst(keep) {
            try? await BackupFiles.remove(old.url)
        }
        var referenced = Set<String>()
        for backup in all.prefix(keep) {
            guard let data = try? Data(contentsOf: backup.url), let file = try? Backup.read(data) else { return }
            for record in file.attachments {
                if let path = record.file { referenced.insert(path) }
                if let path = record.thumbnail { referenced.insert(path) }
            }
        }
        let directory = folder.appending(path: Backup.attachmentsFolder, directoryHint: .isDirectory)
        for name in await BackupFiles.names(in: directory) where !referenced.contains("\(Backup.attachmentsFolder)/\(name)") {
            try? await BackupFiles.remove(directory.appending(path: name))
        }
    }

    /// Brings a backup and its photos and files down from iCloud Drive before restoring it.
    static func download(_ backup: Saved, progress: @escaping (Double) -> Void) async throws -> BackupFile {
        try await BackupFiles.ensureLocal(backup.url)
        let file = try Backup.read(Data(contentsOf: backup.url))
        let folder = backup.url.deletingLastPathComponent()
        let paths = file.attachments.flatMap { [$0.file, $0.thumbnail].compactMap(\.self) }
        for (index, path) in paths.enumerated() {
            try? await BackupFiles.ensureLocal(folder.appending(path: path))
            progress(Double(index + 1) / Double(max(paths.count, 1)))
        }
        return file
    }
}

/// File work for backups: off the main thread, and coordinated so iCloud Drive sees each change cleanly.
nonisolated enum BackupFiles {
    enum FileError: LocalizedError {
        case notDownloaded

        var errorDescription: String? {
            String(localized: "备份还没从 iCloud 云盘下载下来，请连上网络后再试。")
        }
    }

    static func write(_ data: Data, to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            var coordination: NSError?
            var failure: Error?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordination) { url in
                do { try data.write(to: url, options: .atomic) } catch { failure = error }
            }
            if let error = coordination ?? failure { throw error }
        }.value
    }

    static func remove(_ url: URL) async throws {
        try await Task.detached(priority: .utility) {
            var coordination: NSError?
            var failure: Error?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordination) { url in
                do { try FileManager.default.removeItem(at: url) } catch { failure = error }
            }
            if let error = coordination ?? failure { throw error }
        }.value
    }

    static func createDirectory(_ url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }.value
    }

    /// File names in `url`, with iCloud placeholders under the name they will have.
    static func names(in url: URL) async -> [String] {
        await Task.detached(priority: .utility) {
            ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).map { raw in
                raw.hasPrefix(".") && raw.hasSuffix(".icloud") ? String(raw.dropFirst().dropLast(".icloud".count)) : raw
            }
        }.value
    }

    /// Zips `folder` (the system does this when a folder is read "for uploading") into `destination`.
    static func zip(_ folder: URL, to destination: URL) async throws {
        try await Task.detached(priority: .utility) {
            var coordination: NSError?
            var failure: Error?
            NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordination) { zipped in
                do { try FileManager.default.copyItem(at: zipped, to: destination) } catch { failure = error }
            }
            if let error = coordination ?? failure { throw error }
        }.value
    }

    /// Waits for a file that's only in iCloud Drive to download (a minute at most).
    static func ensureLocal(_ url: URL) async throws {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        func isLocal() -> Bool {
            var fresh = url
            fresh.removeAllCachedResourceValues()
            guard let values = try? fresh.resourceValues(forKeys: keys), values.isUbiquitousItem == true else {
                return FileManager.default.fileExists(atPath: url.path)
            }
            return values.ubiquitousItemDownloadingStatus == .current
        }
        if isLocal() { return }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(300))
            if isLocal() { return }
        }
        throw FileError.notDownloaded
    }
}
