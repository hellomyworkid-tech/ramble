import Foundation
import UserNotifications

// Compiled into both the app and the share extension.

/// What the share sheet's 随口记 put by for the app: words to tidy, files for AI to read.
nonisolated struct SharedItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var date = Date.now
    var text = ""
    /// Names in the item's folder.
    var files: [String] = []

    var notificationID: String { "share.\(id.uuidString)" }
}

/// The hand-off between the share extension and the app, in their shared folder. An item appears all
/// at once: it's written to one side and moved into place, so the app never picks up half of one.
nonisolated struct ShareInbox {
    static let appGroup = "group.com.zengji.suikouji"
    /// The most an attachment can be anywhere in the app.
    static let maxFileSize = 50 * 1024 * 1024
    private static let draftsName = ".drafts"
    private static let itemName = "item.json"

    static var shared: ShareInbox? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            .map { ShareInbox(root: $0.appending(path: "ShareInbox", directoryHint: .isDirectory)) }
    }

    let root: URL

    /// A shared item being written. Files have to be copied as they're offered, from any thread:
    /// the system takes them away again afterwards.
    final class Draft: @unchecked Sendable {
        fileprivate let folder: URL
        private let lock = NSLock()
        private var names: [String] = []

        fileprivate init(folder: URL) {
            self.folder = folder
        }

        var files: [String] { lock.withLock { names } }

        /// The file's name, made different from any before it: two photos can both be called image.jpg.
        private func place(_ name: String) -> URL {
            lock.withLock {
                let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
                var candidate = name.isEmpty ? "file" : name
                var count = 1
                while names.contains(candidate) {
                    count += 1
                    candidate = ext.isEmpty ? "\(base) \(count)" : "\(base) \(count).\(ext)"
                }
                names.append(candidate)
                return folder.appending(path: candidate)
            }
        }

        func addFile(at url: URL) throws {
            try FileManager.default.copyItem(at: url, to: place(url.lastPathComponent))
        }

        func addFile(_ data: Data, named name: String) throws {
            try data.write(to: place(name), options: .atomic)
        }
    }

    /// Starts an item. Whatever a killed extension left half-written goes first.
    func makeDraft() throws -> Draft {
        let drafts = root.appending(path: Self.draftsName, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: drafts)
        let folder = drafts.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Draft(folder: folder)
    }

    @discardableResult
    func commit(_ draft: Draft, text: String, now: Date = .now) throws -> SharedItem {
        let item = SharedItem(date: now, text: text, files: draft.files)
        try JSONEncoder().encode(item).write(to: draft.folder.appending(path: Self.itemName), options: .atomic)
        try FileManager.default.moveItem(at: draft.folder, to: folder(of: item))
        return item
    }

    /// Oldest first.
    func pending() -> [SharedItem] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders
            .filter { $0.lastPathComponent != Self.draftsName }
            .compactMap { folder in
                (try? Data(contentsOf: folder.appending(path: Self.itemName))).flatMap { try? JSONDecoder().decode(SharedItem.self, from: $0) }
            }
            .sorted { $0.date < $1.date }
    }

    func urls(of item: SharedItem) -> [URL] {
        item.files.map { folder(of: item).appending(path: $0) }
    }

    /// Done with: its files, and the notification about it if that's still showing.
    func remove(_ item: SharedItem) {
        try? FileManager.default.removeItem(at: folder(of: item))
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [item.notificationID])
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(of item: SharedItem) -> URL {
        root.appending(path: item.id.uuidString, directoryHint: .isDirectory)
    }
}
