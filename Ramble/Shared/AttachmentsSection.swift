import PDFKit
import PhotosUI
import QuickLook
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// A photo or file being edited: already saved (`model` set) or newly added.
struct DraftAttachment: Identifiable {
    let id = UUID()
    var kind: AttachmentKind = .image
    /// Bytes of a newly added attachment; saved ones load lazily from `model`.
    var newData: Data?
    var thumbnail: Data?
    var fileName = ""
    var contentType = ""
    var recognizedText = ""
    var model: Attachment?

    var data: Data? { newData ?? model?.data }

    nonisolated static func image(full: Data, thumbnail: Data) -> DraftAttachment {
        DraftAttachment(kind: .image, newData: full, thumbnail: thumbnail, fileName: "photo.jpg", contentType: UTType.jpeg.identifier)
    }

    static func drafts(from attachments: [Attachment]?) -> [DraftAttachment] {
        (attachments ?? [])
            .sorted { $0.createdAt < $1.createdAt }
            .map { DraftAttachment(kind: $0.kind, thumbnail: $0.thumbnailData, fileName: $0.fileName,
                                   contentType: $0.contentTypeID, recognizedText: $0.recognizedText, model: $0) }
    }

    /// Writes the edited set back: deletes removed attachments, inserts new ones,
    /// and refreshes recognized text on kept ones.
    static func sync(_ drafts: [DraftAttachment], replacing existing: [Attachment]?, in context: ModelContext,
                     attach: (Attachment) -> Void) {
        let kept = Set(drafts.compactMap { $0.model?.persistentModelID })
        for old in existing ?? [] where !kept.contains(old.persistentModelID) {
            context.delete(old)
        }
        for draft in drafts {
            if let model = draft.model {
                // A saved photo marked up while editing.
                if let marked = draft.newData, model.kind == .image {
                    model.replaceImage(marked, thumbnail: draft.thumbnail ?? marked)
                }
                if !draft.recognizedText.isEmpty { model.recognizedText = draft.recognizedText }
                continue
            }
            guard let data = draft.newData else { continue }
            let attachment = draft.kind == .image
                ? Attachment(imageData: data, thumbnailData: draft.thumbnail ?? data, recognizedText: draft.recognizedText)
                : Attachment(fileData: data, fileName: draft.fileName, contentTypeID: draft.contentType,
                             thumbnailData: draft.thumbnail, recognizedText: draft.recognizedText)
            context.insert(attachment)
            attach(attachment)
        }
    }
}

nonisolated enum AttachmentImporter {
    static let maxFileSize = 50 * 1024 * 1024

    enum ImportError: LocalizedError {
        case tooLarge(String), unreadable(String)
        var errorDescription: String? {
            switch self {
            case .tooLarge(let name): String(localized: "「\(name)」超过 50MB，没有添加。")
            case .unreadable(let name): String(localized: "读取「\(name)」失败。")
            }
        }
    }

    /// Copies a file picked in Files into a draft. Images become photos.
    static func draft(fromFileAt url: URL) throws -> DraftAttachment {
        let name = url.lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        if let size = values?.fileSize, size > maxFileSize { throw ImportError.tooLarge(name) }
        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable(name) }
        guard data.count <= maxFileSize else { throw ImportError.tooLarge(name) }

        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .image), let prepared = ImageTools.prepare(data) {
            return .image(full: prepared.full, thumbnail: prepared.thumbnail)
        }
        return DraftAttachment(kind: .document, newData: data, thumbnail: thumbnail(for: data, type: type),
                               fileName: name, contentType: type.identifier)
    }

    static func thumbnail(for data: Data, type: UTType) -> Data? {
        guard type.conforms(to: .pdf), let page = PDFDocument(data: data)?.page(at: 0) else { return nil }
        return page.thumbnail(of: CGSize(width: 320, height: 320), for: .mediaBox).jpegData(compressionQuality: 0.7)
    }

    /// Text for search: OCR for photos and scanned pages, the text layer for PDFs, the content for text files.
    static func extractText(from data: Data, kind: AttachmentKind, contentType: String, fileName: String = "") async -> String {
        await DocumentText.read(data, kind: kind, contentType: contentType, fileName: fileName)
    }
}

/// A square tile: the thumbnail, or an icon and file name for documents.
struct AttachmentTile: View {
    let kind: AttachmentKind
    let thumbnail: Data?
    let fileName: String
    var size: CGFloat = 76

    var body: some View {
        Group {
            if kind == .image, let thumbnail, let image = UIImage(data: thumbnail) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                documentFace
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(.separator), lineWidth: 0.5)
        }
        .accessibilityLabel(Text(kind == .image ? String(localized: "照片") : fileName))
    }

    /// The first page (or a file icon) above the file's name, on a tinted card so a
    /// white page still stands out from a white row.
    private var documentFace: some View {
        VStack(spacing: 0) {
            Group {
                if let thumbnail, let image = UIImage(data: thumbnail) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(.rect(cornerRadius: 2))
                        .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                        .padding([.top, .horizontal], 6)
                } else {
                    Image(systemName: Self.symbol(for: fileName))
                        .font(.system(size: size * 0.3))
                        .foregroundStyle(.tint)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 3) {
                if thumbnail != nil {
                    Image(systemName: Self.symbol(for: fileName))
                        .foregroundStyle(.tint)
                }
                Text((fileName as NSString).deletingPathExtension)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
        }
        .background(Color(.tertiarySystemFill))
    }

    static func symbol(for fileName: String) -> String {
        let type = UTType(filenameExtension: (fileName as NSString).pathExtension) ?? .data
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle.angled" }
        if type.conforms(to: .text) || type.conforms(to: .compositeContent) { return "doc.text" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        return "doc"
    }
}

/// Form section: thumbnails plus "add photo / take photo / add file".
struct AttachmentsSection: View {
    let title: LocalizedStringResource
    @Binding var attachments: [DraftAttachment]
    var addPhotoTitle: LocalizedStringResource = "添加照片"
    var allowsDocuments = false
    /// Opens the library picker as soon as the section appears (e.g. "扫小票记一笔").
    var presentsPickerOnAppear = false
    var onAdd: (DraftAttachment) -> Void = { _ in }

    @State private var picker = AttachmentPickerState()
    @State private var preview: PreviewFile?
    @State private var didAutoPresent = false
    @State private var savedMessage: String?

    var body: some View {
        Section(title) {
            if !attachments.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(attachments) { item in
                        Button {
                            preview = previewFile(for: item)
                        } label: {
                            AttachmentTile(kind: item.kind, thumbnail: item.thumbnail, fileName: item.fileName)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("预览", systemImage: "eye") { preview = previewFile(for: item) }
                            if item.kind == .image {
                                Button("存储到相册", systemImage: "square.and.arrow.down") {
                                    let data = item.data
                                    Task { savedMessage = await PhotoSaver.saveAndDescribe(data) }
                                }
                            }
                            Button("删除", systemImage: "trash", role: .destructive) {
                                attachments.removeAll { $0.id == item.id }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            AttachmentAddButtons(picker: $picker, addPhotoTitle: addPhotoTitle, allowsDocuments: allowsDocuments)
            if let message = picker.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if let savedMessage {
                Text(savedMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .task(id: savedMessage) {
                        try? await Task.sleep(for: .seconds(3))
                        self.savedMessage = nil
                    }
            }
        }
        .attachmentPickers(state: $picker) { draft in
            attachments.append(draft)
            onAdd(draft)
        }
        .attachmentPreview($preview)
        .onAppear {
            if presentsPickerOnAppear, !didAutoPresent {
                didAutoPresent = true
                picker.showsPhotos = true
            }
        }
    }

    /// Marking up a photo here changes the draft; the form's 保存 keeps it, 取消 doesn't.
    private func previewFile(for item: DraftAttachment) -> PreviewFile {
        PreviewFile(draft: item, among: attachments) { id, photo, thumbnail in
            guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
            attachments[index].newData = photo
            attachments[index].thumbnail = thumbnail
        }
    }
}

/// The "add" buttons, shared by forms and the note composer.
struct AttachmentAddButtons: View {
    @Binding var picker: AttachmentPickerState
    var addPhotoTitle: LocalizedStringResource = "添加照片"
    var allowsDocuments = true

    var body: some View {
        HStack(spacing: 16) {
            Button(addPhotoTitle, systemImage: "photo.on.rectangle") { picker.showsPhotos = true }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("拍照", systemImage: "camera") { picker.showsCamera = true }
            }
            if allowsDocuments {
                Button("文件", systemImage: "doc") { picker.showsFiles = true }
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
    }
}

struct AttachmentPickerState {
    var showsPhotos = false
    var showsCamera = false
    var showsFiles = false
    var photoItems: [PhotosPickerItem] = []
    var errorMessage: String?
}

extension View {
    /// Wires the photo library, camera and Files pickers to `onAdd`.
    func attachmentPickers(state: Binding<AttachmentPickerState>, onAdd: @escaping (DraftAttachment) -> Void) -> some View {
        modifier(AttachmentPickers(state: state, onAdd: onAdd))
    }

    /// Opens a draft or saved attachment in Quick Look.
    func attachmentPreview(_ file: Binding<PreviewFile?>) -> some View {
        modifier(AttachmentPreview(file: file))
    }
}

private struct AttachmentPickers: ViewModifier {
    @Binding var state: AttachmentPickerState
    let onAdd: (DraftAttachment) -> Void

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $state.showsPhotos, selection: $state.photoItems, maxSelectionCount: 9, matching: .images)
            .onChange(of: state.photoItems) { _, items in
                guard !items.isEmpty else { return }
                state.photoItems = []
                Task {
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let prepared = ImageTools.prepare(data) {
                            onAdd(.image(full: prepared.full, thumbnail: prepared.thumbnail))
                        }
                    }
                }
            }
            .onChange(of: state.showsCamera) { _, shows in
                guard shows else { return }
                state.showsCamera = false
                CameraPresenter.present { image in
                    Task {
                        // Off the main thread: a 12-megapixel photo takes a moment to shrink.
                        let prepared = await Task.detached(priority: .userInitiated) { ImageTools.prepare(image) }.value
                        if let prepared { onAdd(.image(full: prepared.full, thumbnail: prepared.thumbnail)) }
                    }
                }
            }
            .fileImporter(isPresented: $state.showsFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                state.errorMessage = nil
                guard case .success(let urls) = result else { return }
                for url in urls {
                    do {
                        onAdd(try AttachmentImporter.draft(fromFileAt: url))
                    } catch {
                        state.errorMessage = error.localizedDescription
                    }
                }
            }
    }
}

/// Something to open: a photo in the photo viewer (with the other photos beside it to swipe
/// through, and 存储到相册), any other file in Quick Look.
struct PreviewFile: Identifiable {
    let id = UUID()
    let fileName: String
    let load: () -> Data?
    var photos: [ViewerPhoto] = []
    var start = 0

    /// `drafts`: the attachments shown alongside it. `onMarkup` keeps a marked-up photo (the
    /// draft's id, the photo, its thumbnail); without it the viewer doesn't offer 标记.
    init(draft: DraftAttachment, among drafts: [DraftAttachment] = [],
         onMarkup: ((DraftAttachment.ID, Data, Data) -> Void)? = nil) {
        fileName = draft.fileName.isEmpty ? "photo.jpg" : draft.fileName
        load = { draft.data }
        guard draft.kind == .image else { return }
        let images = (drafts.isEmpty ? [draft] : drafts).filter { $0.kind == .image }
        photos = images.map { item in
            ViewerPhoto(load: { item.data }, replace: onMarkup.map { keep in { keep(item.id, $0, $1) } })
        }
        start = images.firstIndex { $0.id == draft.id } ?? 0
    }

    init(attachment: Attachment, among attachments: [Attachment] = [],
         onMarkup: ((Attachment, Data, Data) -> Void)? = nil) {
        fileName = attachment.fileName.isEmpty ? "photo.jpg" : attachment.fileName
        load = { attachment.data }
        guard attachment.kind == .image else { return }
        let images = (attachments.isEmpty ? [attachment] : attachments).filter { $0.kind == .image }
        photos = images.map { item in
            ViewerPhoto(load: { item.data }, replace: onMarkup.map { keep in { keep(item, $0, $1) } })
        }
        start = images.firstIndex { $0.persistentModelID == attachment.persistentModelID } ?? 0
    }
}

private struct AttachmentPreview: ViewModifier {
    @Binding var file: PreviewFile?
    @State private var url: URL?

    func body(content: Content) -> some View {
        content
            .quickLookPreview($url)
            .onChange(of: file?.id) {
                guard let file else { return }
                self.file = nil
                if !file.photos.isEmpty {
                    PhotoViewer.present(file.photos, at: file.start)
                    return
                }
                guard let data = file.load() else { return }
                // Quick Look needs a real file with the right name to pick a viewer.
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(file.id.uuidString)")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = folder.appendingPathComponent(file.fileName)
                if (try? data.write(to: target)) != nil { url = target }
            }
    }
}

/// The system camera. UIKit presents it over whatever is showing, rather than SwiftUI as a
/// full-screen cover: the cover made the page beneath it "disappear", which threw away a new
/// note that had nothing in it yet and left people back on the list after taking a photo.
final class CameraPresenter: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    /// Holds the delegate while the camera is up (the picker only keeps a weak reference).
    private static var current: CameraPresenter?
    private let onCapture: (UIImage) -> Void

    private init(onCapture: @escaping (UIImage) -> Void) {
        self.onCapture = onCapture
    }

    static func present(onCapture: @escaping (UIImage) -> Void) {
        guard UIImagePickerController.isSourceTypeAvailable(.camera), let top = UIApplication.shared.topViewController else { return }
        let presenter = CameraPresenter(onCapture: onCapture)
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = presenter
        // Over, not instead of, the page: it stays in place underneath.
        picker.modalPresentationStyle = .overFullScreen
        current = presenter
        top.present(picker, animated: true)
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        let image = info[.originalImage] as? UIImage
        picker.dismiss(animated: true)
        Self.current = nil
        if let image { onCapture(image) }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        Self.current = nil
    }
}

extension UIApplication {
    /// The view controller on top of the app's main window: the one to present from.
    var topViewController: UIViewController? {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = (scene?.keyWindow ?? scene?.windows.first)?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
