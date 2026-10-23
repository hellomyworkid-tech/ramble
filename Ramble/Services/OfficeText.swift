import Compression
import Foundation
import UniformTypeIdentifiers

/// Text from Word (.docx), Excel (.xlsx) and PowerPoint (.pptx) files, read on the phone.
/// These are ZIP archives of XML; iOS has no reader for them, so this unpacks the parts
/// that hold the text. The older binary formats (.doc, .xls, .ppt) aren't supported.
nonisolated enum OfficeText {
    enum Format {
        case word, excel, powerPoint
    }

    static func format(of contentType: String, fileName: String = "") -> Format? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let type = UTType(contentType)
        func matches(_ identifier: String, _ extensions: [String]) -> Bool {
            if let type, let target = UTType(identifier), type.conforms(to: target) { return true }
            return extensions.contains(ext) || extensions.contains(type?.preferredFilenameExtension ?? "")
        }
        if matches("org.openxmlformats.wordprocessingml.document", ["docx", "docm"]) { return .word }
        if matches("org.openxmlformats.spreadsheetml.sheet", ["xlsx", "xlsm"]) { return .excel }
        if matches("org.openxmlformats.presentationml.presentation", ["pptx"]) { return .powerPoint }
        return nil
    }

    static func read(_ data: Data, format: Format, limit: Int = DocumentText.maxCharacters) throws -> String {
        let archive = try ZipArchive(data)
        let text: String
        switch format {
        case .word: text = try word(archive)
        case .excel: text = try excel(archive, limit: limit)
        case .powerPoint: text = try powerPoint(archive)
        }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Word

    private static func word(_ archive: ZipArchive) throws -> String {
        let parser = WordParser()
        try parser.parse(archive.data(for: "word/document.xml"))
        return parser.text
    }

    // MARK: Excel

    private static func excel(_ archive: ZipArchive, limit: Int) throws -> String {
        let shared = try archive.optionalData(for: "xl/sharedStrings.xml").map(SharedStringsParser.strings) ?? []
        let styles = try archive.optionalData(for: "xl/styles.xml").map(StylesParser.dateStyles) ?? []
        let workbook = try WorkbookParser.parse(archive.data(for: "xl/workbook.xml"))
        let targets = try archive.optionalData(for: "xl/_rels/workbook.xml.rels").map(RelationshipsParser.targets) ?? [:]
        let calendar = ExcelDates(uses1904: workbook.uses1904)

        var sections: [String] = []
        var length = 0
        for (index, sheet) in workbook.sheets.enumerated() {
            let target = targets[sheet.relationshipID].map { path in
                path.hasPrefix("/") ? String(path.dropFirst()) : "xl/" + path
            } ?? "xl/worksheets/sheet\(index + 1).xml"
            guard let xml = try archive.optionalData(for: target) else { continue }
            let rows = SheetParser.rows(xml, shared: shared, dateStyles: styles, dates: calendar)
            guard !rows.isEmpty else { continue }
            let body = rows.map { $0.joined(separator: " | ") }.joined(separator: "\n")
            let section = (workbook.sheets.count > 1 ? "## \(sheet.name)\n" : "") + body
            sections.append(section)
            length += section.count
            if length > limit { break }
        }
        return sections.joined(separator: "\n\n")
    }

    // MARK: PowerPoint

    private static func powerPoint(_ archive: ZipArchive) throws -> String {
        let slides = archive.names
            .compactMap { name -> (Int, String)? in
                guard name.hasPrefix("ppt/slides/slide"), name.hasSuffix(".xml"),
                      let number = Int(name.dropFirst("ppt/slides/slide".count).dropLast(4)) else { return nil }
                return (number, name)
            }
            .sorted { $0.0 < $1.0 }
        return try slides.compactMap { number, name -> String? in
            let parser = DrawingTextParser()
            try parser.parse(archive.data(for: name))
            let text = parser.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : String(localized: "第 \(number) 页") + "\n" + text
        }
        .joined(separator: "\n\n")
    }
}

// MARK: - ZIP

/// Just enough of the ZIP format for Office files: the central directory, stored and
/// deflated entries.
nonisolated struct ZipArchive {
    enum ZipError: LocalizedError {
        case notAZip, unsupported, missing(String), corrupt
        var errorDescription: String? {
            switch self {
            case .notAZip, .corrupt: String(localized: "文件已损坏，或者不是 Office 文档。")
            case .unsupported: String(localized: "这个文件的压缩方式暂不支持。")
            case .missing: String(localized: "文件里没有找到正文。")
            }
        }
    }

    private struct Entry {
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int
    }

    /// Guards against "zip bombs": no single part may unpack beyond this.
    static let maxEntrySize = 100 * 1024 * 1024

    private let bytes: Data
    private let entries: [String: Entry]

    var names: [String] { Array(entries.keys) }

    init(_ data: Data) throws {
        bytes = data
        let count = data.count
        guard count >= 22 else { throw ZipError.notAZip }
        // The end-of-central-directory record sits in the last 64 KB (it may carry a comment).
        var end = -1
        var position = count - 22
        let lowest = max(0, count - 22 - 65_535)
        while position >= lowest {
            if data.uint32(at: position) == 0x0605_4B50 { end = position; break }
            position -= 1
        }
        guard end >= 0 else { throw ZipError.notAZip }
        let total = Int(data.uint16(at: end + 10))
        let directoryOffset = Int(data.uint32(at: end + 16))
        guard directoryOffset != 0xFFFF_FFFF, directoryOffset < count else { throw ZipError.unsupported }

        var map: [String: Entry] = [:]
        var cursor = directoryOffset
        for _ in 0..<total {
            guard cursor + 46 <= count, data.uint32(at: cursor) == 0x0201_4B50 else { throw ZipError.corrupt }
            let method = data.uint16(at: cursor + 10)
            let compressed = Int(data.uint32(at: cursor + 20))
            let size = Int(data.uint32(at: cursor + 24))
            let nameLength = Int(data.uint16(at: cursor + 28))
            let extraLength = Int(data.uint16(at: cursor + 30))
            let commentLength = Int(data.uint16(at: cursor + 32))
            let offset = Int(data.uint32(at: cursor + 42))
            guard cursor + 46 + nameLength <= count else { throw ZipError.corrupt }
            let name = String(decoding: data[(data.startIndex + cursor + 46)..<(data.startIndex + cursor + 46 + nameLength)], as: UTF8.self)
            map[name] = Entry(method: method, compressedSize: compressed, size: size, localHeaderOffset: offset)
            cursor += 46 + nameLength + extraLength + commentLength
        }
        entries = map
    }

    func optionalData(for name: String) throws -> Data? {
        entries[name] == nil ? nil : try data(for: name)
    }

    func data(for name: String) throws -> Data {
        guard let entry = entries[name] else { throw ZipError.missing(name) }
        let header = entry.localHeaderOffset
        guard header + 30 <= bytes.count, bytes.uint32(at: header) == 0x0403_4B50 else { throw ZipError.corrupt }
        let start = header + 30 + Int(bytes.uint16(at: header + 26)) + Int(bytes.uint16(at: header + 28))
        guard start + entry.compressedSize <= bytes.count, entry.size <= Self.maxEntrySize else { throw ZipError.corrupt }
        let payload = bytes[(bytes.startIndex + start)..<(bytes.startIndex + start + entry.compressedSize)]
        switch entry.method {
        case 0:
            return Data(payload)
        case 8:
            return try Self.inflate(Data(payload), size: entry.size)
        default:
            throw ZipError.unsupported
        }
    }

    /// Raw DEFLATE (what ZIP stores) via the Compression framework, whose ZLIB codec is headerless.
    static func inflate(_ data: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, size,
                                          source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw ZipError.corrupt }
        return output
    }
}

private extension Data {
    nonisolated func uint16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    nonisolated func uint32(at offset: Int) -> UInt32 {
        UInt32(uint16(at: offset)) | UInt32(uint16(at: offset + 2)) << 16
    }
}

// MARK: - XML readers

/// Element names without their namespace prefix ("w:p" → "p").
nonisolated private func localName(_ name: String) -> Substring {
    name.split(separator: ":").last ?? Substring(name)
}

/// Paragraphs, line breaks and tables (cells as "a | b | c") from word/document.xml.
nonisolated private final class WordParser: NSObject, XMLParserDelegate {
    private var lines: [String] = []
    private var line = ""
    private var cells: [String] = []
    private var cell = ""
    private var tableDepth = 0
    private var inText = false

    var text: String {
        (lines + [line]).joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    }

    func parse(_ data: Data) throws {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { throw ZipArchive.ZipError.corrupt }
    }

    private func append(_ text: String) {
        if tableDepth > 0 { cell += text } else { line += text }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch localName(name) {
        case "t": inText = true
        case "tab": append("\t")
        case "br", "cr": append(tableDepth > 0 ? " " : "\n")
        case "tbl": tableDepth += 1
        case "tr" where tableDepth == 1: cells = []
        case "tc" where tableDepth == 1: cell = ""
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch localName(name) {
        case "t": inText = false
        case "p":
            if tableDepth > 0 {
                if !cell.isEmpty, !cell.hasSuffix(" ") { cell += " " }
            } else {
                lines.append(line)
                line = ""
            }
        case "tc" where tableDepth == 1: cells.append(cell.trimmingCharacters(in: .whitespaces))
        case "tr" where tableDepth == 1:
            if cells.contains(where: { !$0.isEmpty }) { lines.append(cells.joined(separator: " | ")) }
        case "tbl": tableDepth -= 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { append(string) }
    }
}

/// Text runs (<a:t>) of a slide, one paragraph per line.
nonisolated private final class DrawingTextParser: NSObject, XMLParserDelegate {
    private(set) var text = ""
    private var inText = false

    func parse(_ data: Data) throws {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { throw ZipArchive.ZipError.corrupt }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "a:t" { inText = true }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "a:t" { inText = false }
        if name == "a:p", !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { text += string }
    }
}

/// xl/sharedStrings.xml: each <si>, with rich-text runs joined and phonetic hints left out.
nonisolated private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current = ""
    private var inText = false
    private var phoneticDepth = 0

    static func strings(_ data: Data) -> [String] {
        let delegate = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch localName(name) {
        case "si": current = ""
        case "rPh": phoneticDepth += 1
        case "t": inText = phoneticDepth == 0
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch localName(name) {
        case "si": strings.append(current)
        case "rPh": phoneticDepth -= 1
        case "t": inText = false
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current += string }
    }
}

/// xl/workbook.xml: sheet names in order, and whether dates count from 1904.
nonisolated private final class WorkbookParser: NSObject, XMLParserDelegate {
    struct Sheet {
        let name: String
        let relationshipID: String
    }

    private(set) var sheets: [Sheet] = []
    private(set) var uses1904 = false

    static func parse(_ data: Data) -> WorkbookParser {
        let delegate = WorkbookParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch localName(name) {
        case "sheet":
            let id = attributes.first { localName($0.key) == "id" }?.value ?? ""
            sheets.append(Sheet(name: attributes["name"] ?? "", relationshipID: id))
        case "workbookPr":
            uses1904 = ["1", "true"].contains(attributes["date1904"] ?? "")
        default:
            break
        }
    }
}

/// A .rels file: relationship id → target path.
nonisolated private final class RelationshipsParser: NSObject, XMLParserDelegate {
    private var targets: [String: String] = [:]

    static func targets(_ data: Data) -> [String: String] {
        let delegate = RelationshipsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.targets
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if localName(name) == "Relationship", let id = attributes["Id"], let target = attributes["Target"] {
            targets[id] = target
        }
    }
}

/// How a spreadsheet cell's number is shown.
nonisolated enum ExcelCellKind {
    case number, date, dateTime, time
}

/// xl/styles.xml: for each cell style, whether it shows a date or time.
nonisolated private final class StylesParser: NSObject, XMLParserDelegate {
    typealias Kind = ExcelCellKind

    private var customFormats: [Int: String] = [:]
    private var kinds: [ExcelCellKind] = []
    private var inCellFormats = false

    static func dateStyles(_ data: Data) -> [ExcelCellKind] {
        let delegate = StylesParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.kinds
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch localName(name) {
        case "numFmt":
            if let id = attributes["numFmtId"].flatMap(Int.init) { customFormats[id] = attributes["formatCode"] ?? "" }
        case "cellXfs":
            inCellFormats = true
        case "xf" where inCellFormats:
            kinds.append(Self.kind(of: attributes["numFmtId"].flatMap(Int.init) ?? 0, custom: customFormats))
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if localName(name) == "cellXfs" { inCellFormats = false }
    }

    static func kind(of id: Int, custom: [Int: String]) -> ExcelCellKind {
        switch id {
        case 14...17, 27...31, 34...36, 50...58: return .date
        case 22: return .dateTime
        case 18...21, 32, 33, 45...47: return .time
        default: break
        }
        guard let code = custom[id] else { return .number }
        // Ignore quoted text and [colour]/[locale] blocks, then look for date and time letters.
        let bare = code.replacingOccurrences(of: #""[^"]*"|\[[^\]]*\]|\\."#, with: "", options: .regularExpression).lowercased()
        let hasDate = bare.contains("y") || bare.contains("d")
        let hasTime = bare.contains("h") || bare.contains("s")
        switch (hasDate, hasTime) {
        case (true, true): return .dateTime
        case (true, false): return .date
        case (false, true): return .time
        case (false, false): return bare.contains("m") && !bare.contains("0") ? .date : .number
        }
    }
}

/// Excel stores dates as days since 1899-12-30 (or 1904-01-01).
nonisolated struct ExcelDates {
    let uses1904: Bool

    func string(_ serial: Double, kind: ExcelCellKind) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let origin = calendar.date(from: uses1904 ? DateComponents(year: 1904, month: 1, day: 1) : DateComponents(year: 1899, month: 12, day: 30))!
        let date = origin.addingTimeInterval((serial * 86_400).rounded())
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        switch kind {
        case .date: formatter.dateFormat = "yyyy-MM-dd"
        case .dateTime: formatter.dateFormat = serial.truncatingRemainder(dividingBy: 1) == 0 ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
        case .time: formatter.dateFormat = "HH:mm"
        case .number: return ExcelDates.number(serial)
        }
        return formatter.string(from: date)
    }

    /// 0.1+0.2-style float noise trimmed: up to 10 significant digits, no trailing zeros.
    static func number(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.10g", value)
    }
}

/// One worksheet: rows of cell texts, empty columns kept in place, trailing ones dropped.
nonisolated private final class SheetParser: NSObject, XMLParserDelegate {
    static let maxRows = 2_000

    private let shared: [String]
    private let dateStyles: [ExcelCellKind]
    private let dates: ExcelDates
    private var rows: [[String]] = []
    private var row: [Int: String] = [:]
    private var nextColumn = 0
    private var cellColumn = 0
    private var cellType = ""
    private var cellStyle = 0
    private var value = ""
    private var collecting = false

    private init(shared: [String], dateStyles: [ExcelCellKind], dates: ExcelDates) {
        self.shared = shared
        self.dateStyles = dateStyles
        self.dates = dates
    }

    static func rows(_ data: Data, shared: [String], dateStyles: [ExcelCellKind], dates: ExcelDates) -> [[String]] {
        let delegate = SheetParser(shared: shared, dateStyles: dateStyles, dates: dates)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.rows
    }

    /// "AB12" → 27 (zero-based column).
    static func column(of reference: String) -> Int? {
        var number = 0
        var sawLetter = false
        for scalar in reference.unicodeScalars {
            guard (65...90).contains(scalar.value) || (97...122).contains(scalar.value) else { break }
            number = number * 26 + Int(Character(scalar).uppercased().unicodeScalars.first!.value - 64)
            sawLetter = true
        }
        return sawLetter ? number - 1 : nil
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch localName(name) {
        case "row":
            row = [:]
            nextColumn = 0
        case "c":
            cellColumn = attributes["r"].flatMap(Self.column) ?? nextColumn
            cellType = attributes["t"] ?? "n"
            cellStyle = attributes["s"].flatMap(Int.init) ?? 0
            value = ""
        case "v", "t":
            collecting = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch localName(name) {
        case "v", "t":
            collecting = false
        case "c":
            row[cellColumn] = display()
            nextColumn = cellColumn + 1
        case "row":
            guard rows.count < Self.maxRows, let last = row.filter({ !$0.value.isEmpty }).keys.max() else { return }
            rows.append((0...last).map { row[$0] ?? "" })
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collecting { value += string }
    }

    private func display() -> String {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch cellType {
        case "s":
            return Int(raw).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? ""
        case "b":
            return raw == "1" ? "TRUE" : "FALSE"
        case "str", "inlineStr", "e":
            return raw
        default:
            guard let number = Double(raw) else { return raw }
            let kind: ExcelCellKind = dateStyles.indices.contains(cellStyle) ? dateStyles[cellStyle] : .number
            return dates.string(number, kind: kind)
        }
    }
}
