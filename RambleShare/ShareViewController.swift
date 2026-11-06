import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// The share sheet's 随口记. An extension gets far too little memory for an AI model, so what's shared
/// is only put by here. The app tidies it the next time it opens, and a notification leads there.
final class ShareViewController: UIViewController {
    private let status = ShareStatus()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareCard(status: status) { [weak self] in self?.finish() })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await save() }
    }

    private func save() async {
        guard let inbox = ShareInbox.shared else {
            status.phase = .failed(String(localized: "没有存成功，再试一次。"))
            return
        }
        do {
            let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
            let draft = try inbox.makeDraft()
            let reading = await ShareReader.read(items, into: draft)
            guard !reading.text.isEmpty || !draft.files.isEmpty else {
                status.phase = .failed(reading.tooLarge > 0 ? Self.tooLargeMessage(reading.tooLarge) : String(localized: "没有能存的内容。"))
                return
            }
            let item = try inbox.commit(draft, text: reading.text)
            await Self.notify(about: item)
            status.phase = .saved(reading.tooLarge > 0 ? Self.tooLargeMessage(reading.tooLarge) : nil)
        } catch {
            status.phase = .failed(String(localized: "没有存成功，再试一次。"))
        }
    }

    private static func tooLargeMessage(_ count: Int) -> String {
        String(localized: "有 \(count) 个文件超过 50MB，没有存。")
    }

    /// The one tap back to the app: an extension isn't allowed to open it. Without permission for
    /// notifications this does nothing, and the app still picks the item up when it opens.
    private static func notify(about item: SharedItem) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "已收到分享")
        content.body = String(localized: "点这里接着整理")
        content.userInfo = ["target": "openApp", "id": ""]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.notificationID, content: content, trigger: nil))
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

/// Reads what was shared: words become text to tidy, photos and files are copied for AI to read.
private enum ShareReader {
    struct Reading {
        var text = ""
        var tooLarge = 0
    }

    /// Below this a page has no article in it: a login, a video, a picture. Its link is the point.
    private static let shortestArticle = 200

    static func read(_ items: [NSExtensionItem], into draft: ShareInbox.Draft) async -> Reading {
        var reading = Reading()
        var words: [String] = []
        var links: [URL] = []
        var title = ""
        for item in items {
            title = item.attributedContentText?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier),
                   let page = await webPage(from: provider) {
                    // Safari ran WebPage.js: the words are there, and the link alone can't be read.
                    words.append(contentsOf: save(page, into: draft))
                    return finished(reading, words: words, links: [], title: "")
                }
                do {
                    if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                        try await copyImage(from: provider, into: draft)
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                        if let url = await loadURL(from: provider) {
                            if url.isFileURL { try await copyFile(from: provider, type: .fileURL, into: draft) } else { links.append(url) }
                        }
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                        if let text = await loadText(from: provider) { words.append(text) }
                    } else if let type = provider.registeredTypeIdentifiers.first.flatMap({ UTType($0) }) {
                        try await copyFile(from: provider, type: type, into: draft)
                    }
                } catch ShareError.tooLarge {
                    reading.tooLarge += 1
                } catch {
                    // Whatever else came with it still counts.
                }
            }
        }
        return finished(reading, words: words, links: links, title: title)
    }

    private static func finished(_ reading: Reading, words: [String], links: [URL], title: String) -> Reading {
        var reading = reading
        var parts = words
        // A title worth keeping is only one that isn't the words themselves.
        if !links.isEmpty, !title.isEmpty, !words.contains(title) { parts.append(title) }
        parts += links.map(\.absoluteString)
        reading.text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return reading
    }

    private struct WebPage {
        var title: String
        var url: String
        var selection: String
        var text: String
    }

    /// Words to tidy: what's selected, or just the link for a page with little in it. A whole
    /// article goes in as a text file instead, for AI to read like any other long document.
    private static func save(_ page: WebPage, into draft: ShareInbox.Draft) -> [String] {
        let selection = page.selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selection.isEmpty { return [selection, page.url] }
        let text = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= shortestArticle else { return [page.title, page.url] }
        let name = page.title.replacingOccurrences(of: "/", with: "-").prefix(60)
        let article = [page.title, page.url, "", text].joined(separator: "\n")
        do {
            try draft.addFile(Data(article.utf8), named: (name.isEmpty ? "page" : String(name)) + ".txt")
            return []
        } catch {
            return [page.title, page.url]
        }
    }

    private static func webPage(from provider: NSItemProvider) async -> WebPage? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier, options: nil) { item, _ in
                let results = (item as? NSDictionary)?[NSExtensionJavaScriptPreprocessingResultsKey] as? NSDictionary
                continuation.resume(returning: results.map {
                    WebPage(title: $0["title"] as? String ?? "", url: $0["url"] as? String ?? "",
                            selection: $0["selection"] as? String ?? "", text: $0["text"] as? String ?? "")
                })
            }
        }
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private static func loadText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                switch item {
                case let text as String: continuation.resume(returning: text)
                case let data as Data: continuation.resume(returning: String(data: data, encoding: .utf8))
                case let url as URL: continuation.resume(returning: try? String(contentsOf: url, encoding: .utf8))
                default: continuation.resume(returning: nil)
                }
            }
        }
    }

    private enum ShareError: Error { case tooLarge, unreadable }

    /// Photos usually come as files. A screenshot just marked up may only exist as an image in memory.
    private static func copyImage(from provider: NSItemProvider, into draft: ShareInbox.Draft) async throws {
        do {
            try await copyFile(from: provider, type: .image, into: draft)
        } catch ShareError.tooLarge {
            throw ShareError.tooLarge
        } catch {
            let image: UIImage? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: UIImage.self) { image, _ in continuation.resume(returning: image as? UIImage) }
            }
            guard let data = image?.jpegData(compressionQuality: 0.9) else { throw ShareError.unreadable }
            try draft.addFile(data, named: "photo.jpg")
        }
    }

    private static func copyFile(from provider: NSItemProvider, type: UTType, into draft: ShareInbox.Draft) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                do {
                    guard let url else { throw error ?? ShareError.unreadable }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= ShareInbox.maxFileSize else { throw ShareError.tooLarge }
                    try draft.addFile(at: url)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

@Observable
private final class ShareStatus {
    enum Phase: Equatable {
        case saving
        case saved(String?)
        case failed(String)
    }

    var phase = Phase.saving
}

/// Saving starts by itself, and a moment after it's done the sheet goes away by itself:
/// sharing shouldn't take a second tap.
private struct ShareCard: View {
    let status: ShareStatus
    let close: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            switch status.phase {
            case .saving:
                ProgressView()
                    .controlSize(.large)
                Text("正在存到随口记…")
                    .foregroundStyle(.secondary)
            case .saved(let warning):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                Text("已存到随口记")
                    .font(.title3.weight(.semibold))
                Text(warning ?? String(localized: "打开随口记就会接着整理。"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                Text(message)
                    .multilineTextAlignment(.center)
                Button("关闭", action: close)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .task(id: status.phase) {
            guard case .saved(let warning) = status.phase else { return }
            // Longer when there's something to read.
            try? await Task.sleep(for: .seconds(warning == nil ? 1.2 : 3))
            if !Task.isCancelled { close() }
        }
    }
}
