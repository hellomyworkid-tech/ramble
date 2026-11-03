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

struct CategoryTotalTests {
    private let container = AppSchema.makeContainer(inMemory: true)

    private func entry(_ amount: Decimal, _ category: LedgerCategory?, in context: ModelContext) -> LedgerEntry {
        let entry = LedgerEntry(kind: .expense, amount: amount, currencyCode: "CNY")
        context.insert(entry)
        entry.category = category
        return entry
    }

    /// 按分类 adds an imported subcategory into its parent and lists the biggest spending first.
    @Test func subcategoriesCountTowardTheirParentLargestFirst() {
        let context = container.mainContext
        let food = LedgerCategory(name: "餐饮", kind: .expense, symbol: "fork.knife", colorHex: "#FF9500", sortOrder: 0)
        let lunch = LedgerCategory(name: "午餐", kind: .expense, symbol: "fork.knife", colorHex: "#FF9500", sortOrder: 1)
        let transport = LedgerCategory(name: "交通", kind: .expense, symbol: "car", colorHex: "#007AFF", sortOrder: 2)
        for category in [food, lunch, transport] { context.insert(category) }
        lunch.parent = food

        let entries = [entry(30, food, in: context), entry(25, lunch, in: context),
                       entry(40, transport, in: context), entry(5, nil, in: context)]
        let totals = CategoryTotal.totals(of: entries)
        #expect(totals.map(\.category?.name) == ["餐饮", "交通", nil])
        #expect(totals.map(\.amount) == [55, 40, 5])
        #expect(totals.map(\.count) == [2, 1, 1])
    }

    @Test func equalAmountsKeepTheCategoriesOrder() {
        let context = container.mainContext
        let home = LedgerCategory(name: "住房", kind: .expense, symbol: "house", colorHex: "#AF52DE", sortOrder: 5)
        let fun = LedgerCategory(name: "娱乐", kind: .expense, symbol: "gamecontroller", colorHex: "#FF2D55", sortOrder: 2)
        for category in [home, fun] { context.insert(category) }
        let totals = CategoryTotal.totals(of: [entry(100, home, in: context), entry(100, fun, in: context)])
        #expect(totals.map(\.category?.name) == ["娱乐", "住房"])
    }
}

struct SearchAndUndoTests {
    private let container = AppSchema.makeContainer(inMemory: true)

    /// 账本 search reaches the note, the category and its parent, the accounts, a receipt's text,
    /// and the amount itself.
    @Test func ledgerSearchLooksBeyondTheNote() {
        let context = container.mainContext
        let food = LedgerCategory(name: "餐饮", kind: .expense, symbol: "fork.knife", colorHex: "#FF9500")
        let coffee = LedgerCategory(name: "咖啡", kind: .expense, symbol: "cup.and.saucer", colorHex: "#A2845E")
        let card = Account(name: "招商信用卡", kind: .creditCard)
        context.insert(food)
        context.insert(coffee)
        context.insert(card)
        coffee.parent = food
        let entry = LedgerEntry(kind: .expense, amount: 3200, currencyCode: "CNY", note: "下午茶")
        context.insert(entry)
        entry.category = coffee
        entry.account = card
        let receipt = Attachment(imageData: Data([1]), thumbnailData: Data([1]), recognizedText: "STARBUCKS 星巴克")
        context.insert(receipt)
        entry.attachments = [receipt]

        for query in ["下午茶", "咖啡", "餐饮", "招商", "starbucks", "3200", "3,200", " 3200 "] {
            #expect(entry.matches(query), "\(query)")
        }
        #expect(!entry.matches("交通"))
        #expect(!entry.matches("320"))
    }

    @Test func taskSearchLooksAtNotesListAndSubtasks() {
        let context = container.mainContext
        let task = TaskItem(title: "交季度报告", listName: "工作")
        task.notes = "找财务要数字"
        context.insert(task)
        let step = Subtask(title: "做 PPT", order: 0)
        context.insert(step)
        task.subtasks = [step]

        for query in ["季度", "财务", "工作", "ppt"] {
            #expect(task.matches(query), "\(query)")
        }
        #expect(!task.matches("家庭"))
    }

    /// A deleted record is only hidden until the time is up: 撤销 leaves it untouched, and a
    /// second deletion lets the first one go through.
    @Test func deletionWaitsForUndo() throws {
        let context = container.mainContext
        let lunch = LedgerEntry(kind: .expense, amount: 35, currencyCode: "CNY", note: "午餐")
        let taxi = LedgerEntry(kind: .expense, amount: 20, currencyCode: "CNY", note: "打车")
        context.insert(lunch)
        context.insert(taxi)
        try context.save()
        let pending = PendingDeletion.shared

        pending.delete([lunch], message: "已删除「午餐」", in: context)
        #expect(pending.hides(lunch))
        #expect(!pending.hides(taxi))
        pending.undo()
        #expect(!pending.hides(lunch))
        #expect(try context.fetchCount(FetchDescriptor<LedgerEntry>()) == 2)

        pending.delete([lunch], message: "已删除「午餐」", in: context)
        pending.delete([taxi], message: "已删除「打车」", in: context)
        #expect(try context.fetchCount(FetchDescriptor<LedgerEntry>()) == 1)
        #expect(pending.hides(taxi))
        pending.commit()
        #expect(try context.fetchCount(FetchDescriptor<LedgerEntry>()) == 0)
        #expect(pending.current == nil)
    }
}
