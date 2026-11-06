import Foundation
import SwiftData
import Testing
@testable import Ramble

/// Amounts as Shortcuts hands them over, with or without a currency sign.
struct PaymentAmountTests {
    @Test(arguments: [
        ("35", "35", "CNY"),
        ("35.5", "35.5", "CNY"),
        ("¥35.00", "35", "CNY"),
        ("￥1,234.50", "1234.5", "CNY"),
        ("CN¥88", "88", "CNY"),
        ("RMB 20", "20", "CNY"),
        ("20元", "20", "CNY"),
        ("HK$1,280.50", "1280.5", "HKD"),
        ("88.00 HKD", "88", "HKD"),
        ("US$12.50", "12.5", "USD"),
        ("$12.50", "12.5", "USD"),
        ("NT$150", "150", "TWD"),
        ("JP¥1,200", "1200", "JPY"),
        ("€9,99", "9.99", "EUR"),
        ("1.234,56 €", "1234.56", "EUR"),
        ("£7.20", "7.2", "GBP"),
        ("thb 300", "300", "THB"),
    ])
    func reads(_ text: String, _ value: String, _ currency: String) throws {
        let amount = try #require(PaymentAmount(text, baseCurrency: "CNY"), "\(text)")
        #expect(amount.value == Decimal(string: value), "\(text)")
        #expect(amount.currency == currency, "\(text)")
    }

    @Test func aSignSeveralCurrenciesShareMeansThePersonsOwn() {
        #expect(PaymentAmount("$5", baseCurrency: "HKD")?.currency == "HKD")
        #expect(PaymentAmount("$5", baseCurrency: "CNY")?.currency == "USD")
        #expect(PaymentAmount("¥500", baseCurrency: "JPY")?.currency == "JPY")
        #expect(PaymentAmount("¥500", baseCurrency: "USD")?.currency == "CNY")
        #expect(PaymentAmount("5", baseCurrency: "EUR")?.currency == "EUR")
        #expect(PaymentAmount("5 ???", baseCurrency: "EUR")?.currency == "EUR")
    }

    @Test(arguments: ["", "abc", "0", "0.00", "-5", "−5.00", "-¥35.00"])
    func onlyAmountsSpentCount(_ text: String) {
        #expect(PaymentAmount(text, baseCurrency: "CNY") == nil, "\(text)")
    }
}

/// A payment recorded with nobody looking.
@MainActor
struct PaymentEntryTests {
    private let container = AppSchema.makeContainer(inMemory: true)

    private func library() throws -> ModelContext {
        let context = container.mainContext
        context.insert(LedgerCategory(name: "餐饮", kind: .expense, symbol: "fork.knife", colorHex: "#D9480F", seedKey: "food"))
        context.insert(LedgerCategory(name: "购物", kind: .expense, symbol: "bag", colorHex: "#C2185B", seedKey: "shopping"))
        context.insert(LedgerCategory(name: "其他", kind: .expense, symbol: "ellipsis", colorHex: "#8E8E93", seedKey: "other-expense"))
        context.insert(LedgerCategory(name: "其他收入", kind: .income, symbol: "ellipsis", colorHex: "#8E8E93", seedKey: "other-income"))
        context.insert(Account(name: "信用卡", kind: .creditCard))
        context.insert(Account(name: "储蓄卡", kind: .debitCard))
        try context.save()
        return context
    }

    private func pay(_ amount: String, at merchant: String, card: String = "", in context: ModelContext) throws -> LedgerEntry {
        try PaymentEntry.record(try #require(PaymentAmount(amount, baseCurrency: "CNY")), merchant: merchant, card: card, in: context)
    }

    @Test func aNewMerchantGoesByItsName() throws {
        let context = try library()
        let coffee = try pay("¥35.00", at: "STARBUCKS COFFEE", in: context)
        #expect(coffee.kind == .expense && coffee.amount == 35 && coffee.currencyCode == "CNY" && coffee.note == "STARBUCKS COFFEE")
        #expect(coffee.category?.name == "餐饮")
        #expect(try pay("20", at: "XYZ TRADING", in: context).category?.name == "其他")
        #expect(try pay("20", at: "", in: context).category?.name == "其他")
    }

    @Test func correctingOneSettlesTheNext() throws {
        let context = try library()
        let first = try pay("20", at: "XYZ TRADING", in: context)
        let shopping = try #require(try context.fetch(FetchDescriptor<LedgerCategory>()).first { $0.name == "购物" })
        first.category = shopping
        first.account = try context.fetch(FetchDescriptor<Account>()).first { $0.name == "储蓄卡" }
        try context.save()

        let next = try pay("30", at: "XYZ TRADING", in: context)
        #expect(next.category?.name == "购物")
        #expect(next.account?.name == "储蓄卡")
    }

    @Test func theCardFindsItsAccount() throws {
        let context = try library()
        #expect(try pay("20", at: "A", card: "招商银行信用卡", in: context).account?.name == "信用卡")
        #expect(try pay("20", at: "B", card: "Visa", in: context).account == nil)
        // The card named beats the one used last time.
        #expect(try pay("20", at: "A", card: "储蓄卡", in: context).account?.name == "储蓄卡")
    }

    @Test func aForeignAmountKeepsItsCurrency() throws {
        let context = try library()
        let entry = try pay("HK$88.50", at: "MTR", in: context)
        #expect(entry.currencyCode == "HKD" && entry.amount == Decimal(string: "88.5"))
    }
}

/// The hand-off between the share extension and the app.
struct ShareInboxTests {
    private func inbox() -> ShareInbox {
        ShareInbox(root: FileManager.default.temporaryDirectory.appending(path: "share-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    private func file(named name: String, containing text: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func wordsAndFilesArriveTogether() throws {
        let inbox = inbox()
        defer { inbox.removeAll() }
        let draft = try inbox.makeDraft()
        try draft.addFile(at: try file(named: "receipt.png", containing: "picture"))
        try inbox.commit(draft, text: "这是上个月的电费单")

        let item = try #require(inbox.pending().first)
        #expect(item.text == "这是上个月的电费单" && item.files == ["receipt.png"])
        let urls = inbox.urls(of: item)
        #expect(try String(contentsOf: urls[0], encoding: .utf8) == "picture")
    }

    @Test func twoFilesWithOneNameBothStay() throws {
        let inbox = inbox()
        defer { inbox.removeAll() }
        let draft = try inbox.makeDraft()
        try draft.addFile(at: try file(named: "image.jpg", containing: "one"))
        try draft.addFile(at: try file(named: "image.jpg", containing: "two"))
        try draft.addFile(Data("three".utf8), named: "image.jpg")
        try inbox.commit(draft, text: "")

        let item = try #require(inbox.pending().first)
        #expect(item.files == ["image.jpg", "image 2.jpg", "image 3.jpg"])
        #expect(try inbox.urls(of: item).map { try String(contentsOf: $0, encoding: .utf8) } == ["one", "two", "three"])
    }

    @Test func nothingShowsUntilItIsAllThere() throws {
        let inbox = inbox()
        defer { inbox.removeAll() }
        let draft = try inbox.makeDraft()
        try draft.addFile(Data("half".utf8), named: "a.txt")
        #expect(inbox.pending().isEmpty)
        // A killed extension's leftovers go when the next share starts, and don't get in its way.
        let next = try inbox.makeDraft()
        try inbox.commit(next, text: "第二次")
        #expect(inbox.pending().map(\.text) == ["第二次"])
    }

    @Test func oldestFirstAndGoneWhenDone() throws {
        let inbox = inbox()
        defer { inbox.removeAll() }
        let now = Date.now
        try inbox.commit(try inbox.makeDraft(), text: "后", now: now)
        try inbox.commit(try inbox.makeDraft(), text: "先", now: now.addingTimeInterval(-60))
        #expect(inbox.pending().map(\.text) == ["先", "后"])

        inbox.remove(try #require(inbox.pending().first))
        #expect(inbox.pending().map(\.text) == ["后"])
    }

    @Test func aDamagedItemIsLeftOut() throws {
        let inbox = inbox()
        defer { inbox.removeAll() }
        let folder = inbox.root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.appending(path: "item.json"))
        #expect(inbox.pending().isEmpty)
    }
}

/// What goes in the system's search.
@MainActor
struct SpotlightRecordTests {
    private let container = AppSchema.makeContainer(inMemory: true)

    private func library() throws -> ModelContext {
        let context = container.mainContext
        let note = Note(title: "装修记录")
        context.insert(note)
        note.append("第一行\n第二行", date: .now.addingTimeInterval(-60), in: context)
        note.append("瓷砖到货了", date: .now, in: context)

        let open = TaskItem(title: "交房租", listName: "家庭")
        open.notes = "转账前先核对"
        context.insert(open)
        let done = TaskItem(title: "体检")
        done.isCompleted = true
        context.insert(done)

        context.insert(Bill(name: "信用卡还款", kind: .creditCard, amount: 2180, currencyCode: "CNY", nextDueDate: .now))
        let ended = Bill(name: "旧账单", kind: .other, amount: 10, currencyCode: "CNY", nextDueDate: .now)
        ended.isActive = false
        context.insert(ended)

        context.insert(ExpiryItem(name: "护照", kind: .document, expiryDate: .now))
        let archived = ExpiryItem(name: "旧保险", kind: .insurance, expiryDate: .now)
        archived.isArchived = true
        context.insert(archived)
        try context.save()
        return context
    }

    @Test func whatGoesIn() throws {
        let records = SpotlightIndex.records(in: try library())
        #expect(Set(records.map(\.title)) == ["装修记录", "第一行 第二行", "瓷砖到货了", "交房租", "信用卡还款", "护照"])
        // Search only matches titles, so a note's words have to be titles of their own.
        let entry = try #require(records.first { $0.title == "瓷砖到货了" })
        #expect(entry.kind == .noteEntry && entry.details.hasPrefix("装修记录"))
        let task = try #require(records.first { $0.title == "交房租" })
        #expect(task.details.contains("家庭") && task.text.contains("转账前先核对"))
        #expect(try #require(records.first { $0.title == "信用卡还款" }).details.contains("2,180"))
    }

    @Test func onlyWhatChangedGoesAgain() {
        let one = SpotlightRecord(kind: .task, reference: "a", title: "交房租", details: "")
        let two = SpotlightRecord(kind: .bill, reference: "b", title: "话费", details: "")
        var edited = one
        edited.title = "交水费"

        let first = SpotlightIndex.changes(from: [:], to: [one, two])
        #expect(first.changed.map(\.id) == [one.id, two.id] && first.removed.isEmpty)

        let indexed = [one.id: one.fingerprint, two.id: two.fingerprint]
        let same = SpotlightIndex.changes(from: indexed, to: [one, two])
        #expect(same.changed.isEmpty && same.removed.isEmpty)

        let later = SpotlightIndex.changes(from: indexed, to: [edited])
        #expect(later.changed.map(\.title) == ["交水费"] && later.removed == [two.id])
    }

    @Test func aResultLeadsToItsRecord() throws {
        let context = try library()
        let records = SpotlightIndex.records(in: context)
        func opened(_ title: String) throws -> AppRouter {
            let router = AppRouter()
            SpotlightIndex.open(try #require(records.first { $0.title == title }).id, router: router, context: context)
            return router
        }
        let note = try #require(try context.fetch(FetchDescriptor<Note>()).first)
        #expect(try opened("装修记录").focus == .note(note.persistentModelID))
        #expect(try opened("瓷砖到货了").focus == .note(note.persistentModelID))
        #expect(try opened("交房租").tab == .tasks)
        #expect(try opened("信用卡还款").tab == .reminders)
        #expect(try opened("护照").tab == .reminders)
    }

    @Test func anIdItCannotReadGoesNowhere() {
        let router = AppRouter()
        SpotlightIndex.open("nonsense", router: router, context: container.mainContext)
        SpotlightIndex.open("note|nonsense", router: router, context: container.mainContext)
        #expect(router.focus == nil && router.tab == .today)
    }
}
