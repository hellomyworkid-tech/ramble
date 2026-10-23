import Foundation
import UIKit
import Vision

nonisolated enum ImageTools {
    /// Downscales a picked photo for storage, plus a small thumbnail. Nil if it isn't an image.
    static func prepare(_ data: Data, maxSide: CGFloat = 2048, thumbnailSide: CGFloat = 320) -> (full: Data, thumbnail: Data)? {
        guard let image = UIImage(data: data) else { return nil }
        guard let full = resized(image, maxSide: maxSide).jpegData(compressionQuality: 0.8),
              let thumbnail = resized(image, maxSide: thumbnailSide).jpegData(compressionQuality: 0.7)
        else { return nil }
        return (full, thumbnail)
    }

    private static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// On-device text recognition (Vision). Nothing leaves the phone.
nonisolated enum ReceiptScanner {
    /// Lines of text, top to bottom.
    static func recognizeLines(in imageData: Data) async throws -> [String] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en-US")]
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: imageData)
        let fragments = observations.compactMap { observation -> TextFragment? in
            guard let text = observation.topCandidates(1).first?.string.trimmed, !text.isEmpty else { return nil }
            return TextFragment(text: text, rect: observation.boundingBox.cgRect)
        }
        return rows(from: fragments)
    }

    struct TextFragment {
        let text: String
        /// Normalized, origin at the bottom left (Vision's convention).
        let rect: CGRect
    }

    /// Receipts print the label on the left and the amount far to the right, and Vision
    /// returns them as separate fragments. Fragments sharing a baseline become one row,
    /// read left to right, so "实付" and "34.40" stay together.
    static func rows(from fragments: [TextFragment]) -> [String] {
        var rows: [[TextFragment]] = []
        for fragment in fragments.sorted(by: { $0.rect.midY > $1.rect.midY }) {
            if let last = rows.indices.last, let anchor = rows[last].first,
               abs(anchor.rect.midY - fragment.rect.midY) < min(anchor.rect.height, fragment.rect.height) * 0.5 {
                rows[last].append(fragment)
            } else {
                rows.append([fragment])
            }
        }
        return rows.map { row in
            row.sorted { $0.rect.minX < $1.rect.minX }.map(\.text).joined(separator: " ")
        }
    }
}

nonisolated struct ReceiptInfo: Equatable {
    var amount: Decimal?
    var merchant: String?
    var date: Date?

    var isEmpty: Bool { amount == nil && merchant == nil && date == nil }
}

/// Picks the total, merchant and date out of receipt text. Heuristic by design:
/// the result only pre-fills the form, and the person confirms it.
nonisolated enum ReceiptParser {
    /// Most decisive first: what was actually paid (after discounts) beats what was due, which beats a subtotal.
    static let totalKeywords = ["实付", "应付", "应收", "支付金额", "合计", "总计", "总额", "总金额", "金额", "小计",
                                "TOTAL", "Total", "AMOUNT", "Amount"]
    /// Lines that carry numbers but never the total. On cash receipts 实收/现金 is the cash
    /// handed over, followed by 找零.
    static let ignoredKeywords = ["实收", "现金", "收现", "找零", "优惠", "折扣", "积分", "数量", "件数", "单价",
                                  "电话", "Tel", "TEL", "会员", "卡号", "订单", "CHANGE", "Change", "CASH", "Cash"]
    static let boilerplate = ["欢迎", "光临", "小票", "收银", "发票", "RECEIPT", "Receipt", "谢谢", "WELCOME", "Welcome"]

    static func parse(_ lines: [String], calendar: Calendar = .current) -> ReceiptInfo {
        ReceiptInfo(amount: total(in: lines), merchant: merchant(in: lines), date: date(in: lines, calendar: calendar))
    }

    static func total(in lines: [String]) -> Decimal? {
        for keyword in totalKeywords {
            for (index, line) in lines.enumerated() where line.contains(keyword) {
                guard !ignoredKeywords.contains(where: line.contains) else { continue }
                if let value = amounts(in: line).last { return value }
                // The value is often printed on the next line, under the label.
                if index + 1 < lines.count, let value = amounts(in: lines[index + 1]).first { return value }
            }
        }
        // No label found: the largest money-looking number (two decimals) is usually the total.
        let candidates = lines
            .filter { line in !ignoredKeywords.contains(where: line.contains) && date(in: [line]) == nil }
            .flatMap { line in moneyLike(in: line) }
        return candidates.max()
    }

    static func merchant(in lines: [String]) -> String? {
        lines.prefix(4).first { line in
            let letters = line.filter { $0.isLetter }.count
            let digits = line.filter { $0.isNumber }.count
            return letters >= 2 && digits <= letters / 2 && !boilerplate.contains(where: line.contains)
        }
    }

    static func date(in lines: [String], calendar: Calendar = .current) -> Date? {
        let pattern = #/(20\d{2})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})/#
        for line in lines {
            guard let match = line.firstMatch(of: pattern),
                  let year = Int(match.1), let month = Int(match.2), let day = Int(match.3),
                  let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  calendar.component(.day, from: date) == day
            else { continue }
            return date
        }
        return nil
    }

    /// Every number on the line that could be an amount ("¥1,280.50", "35", "35.5").
    static func amounts(in line: String) -> [Decimal] {
        numberTokens(in: line).compactMap { token in
            let decimals = token.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first?.count ?? 0
            guard decimals <= 2 else { return nil }
            return Decimal(string: token.replacingOccurrences(of: ",", with: ""))
        }.filter { $0 > 0 && $0 < 1_000_000 }
    }

    /// Numbers written with exactly two decimals, the way prices are printed.
    private static func moneyLike(in line: String) -> [Decimal] {
        numberTokens(in: line).compactMap { token in
            guard token.split(separator: ".").dropFirst().first?.count == 2 else { return nil }
            return Decimal(string: token.replacingOccurrences(of: ",", with: ""))
        }
    }

    /// Whole runs of digits (with thousands commas and one decimal point), so "13800138000"
    /// stays one token rather than yielding a fake price from its tail.
    private static func numberTokens(in line: String) -> [String] {
        line.matches(of: #/\d[\d,]*(?:\.\d+)?/#).map { String($0.output).trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
    }
}
