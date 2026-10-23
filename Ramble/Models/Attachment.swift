import Foundation
import SwiftData

/// A photo or file attached to a ledger entry (receipt), an expiry item (document scan)
/// or a note entry.
@Model
final class Attachment {
    var kindRaw: String = AttachmentKind.image.rawValue
    /// The full image, kept outside the database file (and as a CKAsset once synced).
    @Attribute(.externalStorage) var imageData: Data?
    /// A document's bytes, likewise outside the database file.
    @Attribute(.externalStorage) var fileData: Data?
    /// Small JPEG for lists and grids (images, and a PDF's first page).
    var thumbnailData: Data?
    var fileName: String = ""
    /// UTType identifier, e.g. "com.adobe.pdf".
    var contentTypeID: String = ""
    var byteCount: Int = 0
    /// Text read from the image or document, kept for search.
    var recognizedText: String = ""
    var createdAt: Date = Date.now

    var entry: LedgerEntry?
    var expiry: ExpiryItem?
    var noteEntry: NoteEntry?

    init(imageData: Data, thumbnailData: Data, recognizedText: String = "") {
        self.imageData = imageData
        self.thumbnailData = thumbnailData
        self.recognizedText = recognizedText
        self.byteCount = imageData.count
        self.createdAt = .now
    }

    init(fileData: Data, fileName: String, contentTypeID: String, thumbnailData: Data?, recognizedText: String = "") {
        self.kindRaw = AttachmentKind.document.rawValue
        self.fileData = fileData
        self.fileName = fileName
        self.contentTypeID = contentTypeID
        self.thumbnailData = thumbnailData
        self.recognizedText = recognizedText
        self.byteCount = fileData.count
        self.createdAt = .now
    }

    var kind: AttachmentKind { AttachmentKind(rawValue: kindRaw) ?? .image }

    /// The bytes to preview or share.
    var data: Data? { kind == .image ? imageData : fileData }
}

nonisolated enum AttachmentKind: String, Codable {
    case image, document
}
