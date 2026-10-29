import Foundation
import SwiftData
import Testing
import UIKit
@testable import Ramble

struct ExchangeRateTests {
    private func table() -> RateTable {
        RateTable(base: "CNY", rates: ["CNY": 1, "USD": 0.149247, "JPY": 23.62825], updatedAt: .now, fetchedAt: .now)
    }

    @Test func ratesInvertToTheBaseCurrency() {
        #expect(table().rateToBase("CNY") == 1)
        #expect(table().rateToBase("USD") == Decimal(string: "6.700302"))
        #expect(table().rateToBase("XYZ") == nil)
    }

    @Test func parsesTheProviderPayload() throws {
        let json = #"{"result":"success","base_code":"CNY","time_last_update_unix":1791763352,"rates":{"CNY":1,"USD":0.149247}}"#
        let parsed = try ExchangeRates.parse(Data(json.utf8), fetchedAt: .now)
        #expect(parsed.base == "CNY")
        #expect(parsed.rates["USD"] == 0.149247)
        #expect(throws: (any Error).self) {
            try ExchangeRates.parse(Data(#"{"result":"error","base_code":"CNY","time_last_update_unix":0,"rates":{}}"#.utf8), fetchedAt: .now)
        }
    }

    @Test func cachedTableSurvivesRelaunchAndRespectsTheBase() throws {
        let defaults = try #require(UserDefaults(suiteName: "rates-\(UUID().uuidString)"))
        defaults.set(JSONStore.encode(table()), forKey: ExchangeRates.storageKey)
        let rates = ExchangeRates(defaults: defaults)
        #expect(rates.rateToBase("JPY", base: "CNY") == Decimal(string: "0.042322"))
        #expect(rates.rateToBase("USD", base: "HKD") == nil)
        #expect(rates.rateToBase("HKD", base: "HKD") == 1)
    }
}

struct PeriodBoundaryTests {
    /// A salary booked at 00:00 on 1 October belongs to October only.
    @Test func monthBoundaryIsHalfOpen() throws {
        let calendar = Calendar.current
        let september = try #require(calendar.dateInterval(of: .month, for: calendar.date(from: DateComponents(year: 2026, month: 9, day: 15))!))
        let octoberFirst = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        #expect(september.contains(octoberFirst))
        #expect(!september.holds(octoberFirst))
        #expect(september.holds(september.start))
    }
}

struct ReceiptParserTests {
    @Test func paidAfterDiscountWinsOverSubtotalCashAndChange() {
        let lines = ["全家便利店", "2026-10-11 12:30", "可乐 3.50", "面包 8.00", "合计 11.50", "优惠 -1.50",
                     "实付 10.00", "现金 20.00", "找零 10.00"]
        let info = ReceiptParser.parse(lines)
        #expect(info.amount == 10)
        #expect(info.merchant == "全家便利店")
        #expect(info.date == Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 11)))
    }

    @Test func cashTenderedIsNotTheTotal() {
        #expect(ReceiptParser.parse(["超市", "应收 11.50", "实收 20.00", "找零 8.50"]).amount == Decimal(string: "11.5"))
    }

    @Test func totalPrintedUnderItsLabel() {
        #expect(ReceiptParser.parse(["沃尔玛超市", "合计", "¥128.50"]).amount == Decimal(string: "128.5"))
    }

    @Test func englishReceipts() {
        let info = ReceiptParser.parse(["STARBUCKS", "Latte 32.00", "TOTAL 35.00"])
        #expect(info.amount == 35)
        #expect(info.merchant == "STARBUCKS")
    }

    @Test func withoutALabelTheLargestPriceIsUsed() {
        #expect(ReceiptParser.parse(["小面馆", "牛肉面 1 x 22.00", "加蛋 2 x 3.00"]).amount == 22)
    }

    @Test func phoneNumbersAndBoilerplateAreIgnored() {
        let info = ReceiptParser.parse(["欢迎光临", "喜茶 HEYTEA", "电话 13800138000", "合计 1,288.00"])
        #expect(info.amount == 1288)
        #expect(info.merchant == "喜茶 HEYTEA")
    }

    @Test func chineseDatesAndImpossibleDates() {
        #expect(ReceiptParser.date(in: ["日期：2026年3月12日"]) == Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 12)))
        #expect(ReceiptParser.date(in: ["2026-02-30"]) == nil)
    }
}

struct ReceiptScannerTests {
    /// Renders a receipt and reads it back with Vision, end to end on the device.
    @Test func readsARenderedReceipt() async throws {
        let lines = ["全家便利店", "2026-10-11", "合计            128.50"]
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 600))
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 60, y: 60 + index * 160),
                                        withAttributes: [.font: UIFont.systemFont(ofSize: 80, weight: .medium), .foregroundColor: UIColor.black])
            }
        }
        let data = try #require(image.pngData())

        let recognized = try await ReceiptScanner.recognizeLines(in: data)
        #expect(recognized.contains { $0.contains("128.50") })
        #expect(ReceiptParser.parse(recognized).amount == Decimal(string: "128.5"))
    }

    /// Label and amount arrive as separate fragments, in either order.
    @Test func fragmentsOnOneBaselineBecomeOneRow() {
        typealias F = ReceiptScanner.TextFragment
        let fragments = [
            F(text: "34.40", rect: CGRect(x: 0.42, y: 0.30, width: 0.15, height: 0.03)),
            F(text: "合计", rect: CGRect(x: 0.08, y: 0.41, width: 0.10, height: 0.03)),
            F(text: "实付", rect: CGRect(x: 0.08, y: 0.301, width: 0.10, height: 0.03)),
            F(text: "36.40", rect: CGRect(x: 0.42, y: 0.408, width: 0.15, height: 0.03)),
        ]
        let rows = ReceiptScanner.rows(from: fragments)
        #expect(rows == ["合计 36.40", "实付 34.40"])
        #expect(ReceiptParser.parse(rows).amount == Decimal(string: "34.4"))
    }

    @Test func photosAreDownscaledWithAThumbnail() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 2000)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        }
        let jpeg = try #require(image.jpegData(compressionQuality: 0.9))
        let prepared = try #require(ImageTools.prepare(jpeg))
        let full = try #require(UIImage(data: prepared.full))
        let thumbnail = try #require(UIImage(data: prepared.thumbnail))
        #expect(max(full.size.width, full.size.height) == 2048)
        #expect(max(thumbnail.size.width, thumbnail.size.height) == 320)
        #expect(ImageTools.prepare(Data("not an image".utf8)) == nil)
    }
}

struct AttachmentTests {
    private let container = AppSchema.makeContainer(inMemory: true)

    @Test func photoEditsSyncAndCascadeWithTheEntry() throws {
        let context = container.mainContext
        let entry = LedgerEntry(kind: .expense, amount: 35, currencyCode: "CNY")
        context.insert(entry)
        let photos = [DraftAttachment.image(full: Data([1]), thumbnail: Data([1])), DraftAttachment.image(full: Data([2]), thumbnail: Data([2]))]
        DraftAttachment.sync(photos, replacing: entry.attachments, in: context) { $0.entry = entry }
        try context.save()
        #expect(entry.attachments?.count == 2)

        let kept = Array(DraftAttachment.drafts(from: entry.attachments).prefix(1))
        DraftAttachment.sync(kept, replacing: entry.attachments, in: context) { $0.entry = entry }
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Ramble.Attachment>()) == 1)

        context.delete(entry)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Ramble.Attachment>()) == 0)
    }

    /// 标记 on a saved photo in a form changes the draft; saving the form puts it in place of the
    /// old photo, in the same attachment, keeping its text for search.
    @Test func markedUpPhotoReplacesTheSavedOneOnSave() throws {
        let context = container.mainContext
        let entry = LedgerEntry(kind: .expense, amount: 35, currencyCode: "CNY")
        context.insert(entry)
        DraftAttachment.sync([DraftAttachment.image(full: Data([1]), thumbnail: Data([1]))], replacing: nil, in: context) { $0.entry = entry }
        try context.save()
        let saved = try #require(entry.attachments?.first)
        saved.recognizedText = "小票"

        var drafts = DraftAttachment.drafts(from: entry.attachments)
        drafts[0].newData = Data([7, 7, 7])
        drafts[0].thumbnail = Data([7])
        DraftAttachment.sync(drafts, replacing: entry.attachments, in: context) { $0.entry = entry }
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<Ramble.Attachment>()) == 1)
        #expect(saved.imageData == Data([7, 7, 7]))
        #expect(saved.thumbnailData == Data([7]))
        #expect(saved.byteCount == 3)
        #expect(saved.recognizedText == "小票")
    }

    @Test func changingTheBaseCurrencyReconvertsEntries() throws {
        let context = container.mainContext
        let defaults = try #require(UserDefaults(suiteName: "rates-\(UUID().uuidString)"))
        let hkdTable = RateTable(base: "HKD", rates: ["HKD": 1, "CNY": 0.853648, "USD": 0.127396], updatedAt: .now, fetchedAt: .now)
        defaults.set(JSONStore.encode(hkdTable), forKey: ExchangeRates.storageKey)
        let rates = ExchangeRates(defaults: defaults)

        let lunch = LedgerEntry(kind: .expense, amount: 35, currencyCode: "CNY")
        let coffee = LedgerEntry(kind: .expense, amount: 5, currencyCode: "USD")
        context.insert(lunch)
        context.insert(coffee)
        rates.recalculateEntries(in: context, base: "HKD")

        #expect(lunch.rateToBase == hkdTable.rateToBase("CNY"))
        #expect(coffee.rateToBase == hkdTable.rateToBase("USD"))
    }
}
