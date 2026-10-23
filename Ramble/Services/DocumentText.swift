import Foundation
import PDFKit
import UIKit
import UniformTypeIdentifiers

/// Reads the text out of photos and files on the device: Vision for photos and scanned
/// pages, the text layer for PDFs that have one, the content for plain text files.
nonisolated enum DocumentText {
    /// Pages beyond this are skipped; a checkup report rarely runs longer.
    static let maxPages = 30
    static let maxCharacters = 40_000

    /// What reading one file involves, for progress ("第 3/12 页").
    static func pageCount(of data: Data, kind: AttachmentKind, contentType: String) -> Int {
        guard kind == .document, isPDF(contentType) else { return 1 }
        return min(PDFDocument(data: data)?.pageCount ?? 1, maxPages)
    }

    /// The file's text. `progress` is called with the number of pages done.
    static func read(_ data: Data, kind: AttachmentKind, contentType: String, fileName: String = "",
                     progress: (Int) async -> Void = { _ in }) async -> String {
        if kind == .image {
            let text = await recognize(imageData: data)
            await progress(1)
            return text
        }
        if isPDF(contentType), let pdf = PDFDocument(data: data) {
            var pages: [String] = []
            for index in 0..<min(pdf.pageCount, maxPages) {
                guard let page = pdf.page(at: index) else { continue }
                let layer = page.string?.trimmed ?? ""
                // A scan has no text layer (or only a stamp's worth): read the picture instead.
                if meaningfulCount(layer) >= 20 {
                    pages.append(layer)
                } else if let image = render(page) {
                    pages.append(await recognize(imageData: image))
                }
                await progress(index + 1)
            }
            return String(pages.joined(separator: "\n\n").prefix(maxCharacters))
        }
        if let format = OfficeText.format(of: contentType, fileName: fileName) {
            let text = (try? OfficeText.read(data, format: format)) ?? ""
            await progress(1)
            return text
        }
        if let type = UTType(contentType), type.conforms(to: .text) {
            await progress(1)
            return String(String(decoding: data, as: UTF8.self).prefix(maxCharacters))
        }
        return ""
    }

    /// Whether the AI can be shown the file itself instead of its text.
    static func canSendOriginal(kind: AttachmentKind, contentType: String) -> Bool {
        kind == .image || isPDF(contentType)
    }

    /// Whether there's anything to read: photos, PDFs, text, and Word/Excel/PowerPoint (not the old .doc/.xls).
    static func isReadable(kind: AttachmentKind, contentType: String, fileName: String = "") -> Bool {
        if kind == .image || isPDF(contentType) { return true }
        if OfficeText.format(of: contentType, fileName: fileName) != nil { return true }
        return UTType(contentType)?.conforms(to: .text) ?? false
    }

    /// Letters, digits and CJK characters: what's left once OCR noise and layout are ignored.
    static func meaningfulCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (CharacterSet.alphanumerics.contains($1) ? 1 : 0) }
    }

    /// Too little text for the pages read: a blurry photo, handwriting or a complex table.
    static func isPoor(_ text: String, pages: Int) -> Bool {
        meaningfulCount(text) < 30 * max(1, pages)
    }

    /// Identity card numbers are never needed to summarize a document; they stay on the phone.
    static func redactingIDs(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![0-9])[1-9][0-9]{16}[0-9Xx](?![0-9A-Za-z])"#) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: String(localized: "[证件号已隐去]"))
    }

    /// For a small on-device model: the opening lines (title, date, who issued it) plus
    /// every line that looks like a finding, conclusion or follow-up, up to `limit`.
    static func condensed(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { String($0).trimmed }
        let markers = ["↑", "↓", "偏高", "偏低", "阳性", "异常", "超出", "建议", "复查", "随访", "结论", "印象", "诊断", "提示",
                       "到期", "有效期", "期限", "截止", "保修", "质保", "租金", "金额", "合计", "总计",
                       "High", "Low", "abnormal", "positive", "follow", "expire", "total"]
        var kept: [String] = Array(lines.prefix(8))
        for line in lines.dropFirst(8) where markers.contains(where: { line.localizedCaseInsensitiveContains($0) }) || flaggedValue(line) {
            kept.append(line)
        }
        var result = ""
        for line in kept where result.count + line.count + 1 <= limit {
            result += line + "\n"
        }
        return result.trimmed
    }

    /// Lab tables flag results with a lone H or L after the value ("2.10 H").
    private static func flaggedValue(_ line: String) -> Bool {
        line.range(of: #"[0-9]\s*(H|L)\b"#, options: .regularExpression) != nil
    }

    private static func isPDF(_ contentType: String) -> Bool {
        UTType(contentType)?.conforms(to: .pdf) ?? false
    }

    private static func recognize(imageData: Data) async -> String {
        ((try? await ReceiptScanner.recognizeLines(in: imageData)) ?? []).joined(separator: "\n")
    }

    /// A page as an image big enough for small print (about 2000 px on the long side).
    private static func render(_ page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = 2000 / max(bounds.width, bounds.height)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return page.thumbnail(of: size, for: .mediaBox).jpegData(compressionQuality: 0.85)
    }
}
