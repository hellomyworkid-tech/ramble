import Foundation
import SwiftData
import Testing
@testable import Ramble

@MainActor
struct BackupTests {
    /// A small library touching every model and relationship.
    private func makeLibrary() throws -> ModelContainer {
        let container = AppSchema.makeContainer(inMemory: true)
        let context = container.mainContext
        let card = Account(name: "招行信用卡", kind: .creditCard)
        card.creditLimit = 30_000
        card.paymentDueDay = 15
        let cash = Account(name: "现金", kind: .cash, initialBalance: 200)
        let food = LedgerCategory(name: "餐饮", kind: .expense, symbol: "fork.knife", colorHex: "#FF9500", seedKey: "food")
        let coffee = LedgerCategory(name: "咖啡", kind: .expense, symbol: "cup.and.saucer", colorHex: "#A2845E")
        coffee.parent = food
        [card, cash].forEach(context.insert)
        [food, coffee].forEach(context.insert)

        let bill = Bill(name: "信用卡还款", kind: .creditCard, amount: 2180, nextDueDate: .now,
                        recurrence: .monthly(day: 15))
        context.insert(bill)
        bill.creditAccount = card
        bill.account = cash

        let lunch = LedgerEntry(kind: .expense, amount: Decimal(string: "35.5")!, currencyCode: "CNY", note: "午餐", source: .ai)
        context.insert(lunch)
        lunch.category = coffee
        lunch.account = cash
        let paid = LedgerEntry(kind: .transfer, amount: 2180, currencyCode: "CNY", source: .bill)
        context.insert(paid)
        paid.account = cash
        paid.toAccount = card
        paid.bill = bill
        let budget = Budget(amount: 800)
        context.insert(budget)
        budget.category = food

        let passport = ExpiryItem(name: "护照", kind: .document, expiryDate: .now.addingTimeInterval(86_400 * 300), isDayUncertain: true)
        context.insert(passport)

        let note = Note(title: "装修记录")
        note.isPinned = true
        context.insert(note)
        let noteEntry = NoteEntry(text: "下周三可以铺砖。记得提前把瓷砖搬上楼。", source: .ai)
        noteEntry.isKeyPoint = true
        noteEntry.highlights = ["下周三可以铺砖"]
        context.insert(noteEntry)
        noteEntry.note = note

        let task = TaskItem(title: "铺砖", dueDate: .now, hasDueTime: false, priority: .high, listName: "家庭")
        task.reminderMinutes = [0, 60]
        task.sourceQuote = "下周三可以铺砖"
        context.insert(task)
        task.sourceEntry = noteEntry
        let subtask = Subtask(title: "买水泥", order: 0)
        subtask.isDone = true
        context.insert(subtask)
        subtask.task = task

        let receipt = Attachment(imageData: Data([1, 2, 3, 4]), thumbnailData: Data([9]), recognizedText: "小票 35.5")
        context.insert(receipt)
        receipt.entry = lunch
        let scan = Attachment(fileData: Data("%PDF".utf8), fileName: "护照.pdf", contentTypeID: "com.adobe.pdf", thumbnailData: nil)
        context.insert(scan)
        scan.expiry = passport
        try context.save()
        return container
    }

    @Test func aBackupRestoresEveryRecordAndLink() throws {
        let source = try makeLibrary()
        let file = try Backup.make(from: source.mainContext)
        let data = try Backup.encoder().encode(file)
        let read = try Backup.read(data)
        #expect(read.summary.contains("2 条账目"))

        let target = AppSchema.makeContainer(inMemory: true)
        let context = target.mainContext
        // Whatever was there before is replaced.
        context.insert(TaskItem(title: "会被替换"))
        try context.save()
        try Backup.restore(read, into: context)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.map(\.title) == ["铺砖"])
        let task = try #require(tasks.first)
        #expect(task.priority == .high && task.listName == "家庭" && task.reminderMinutes == [0, 60])
        #expect(task.sortedSubtasks.map(\.title) == ["买水泥"])
        #expect(task.sortedSubtasks.first?.isDone == true)
        #expect(task.sourceEntry?.note?.title == "装修记录")
        #expect(task.sourceEntry?.highlights == ["下周三可以铺砖"])

        let entries = try context.fetch(FetchDescriptor<LedgerEntry>())
        let lunch = try #require(entries.first { $0.note == "午餐" })
        #expect(lunch.amount == Decimal(string: "35.5"))
        #expect(lunch.category?.name == "咖啡" && lunch.category?.parent?.name == "餐饮")
        #expect(lunch.source == .ai)
        #expect(lunch.attachments?.first?.imageData == Data([1, 2, 3, 4]))
        let paid = try #require(entries.first { $0.kind == .transfer })
        #expect(paid.toAccount?.name == "招行信用卡" && paid.bill?.name == "信用卡还款")

        let bill = try #require(try context.fetch(FetchDescriptor<Bill>()).first)
        #expect(bill.recurrence?.monthDay == 15 && bill.creditAccount?.creditLimit == 30_000)
        #expect(try context.fetch(FetchDescriptor<Budget>()).first?.category?.name == "餐饮")
        let passport = try #require(try context.fetch(FetchDescriptor<ExpiryItem>()).first)
        #expect(passport.isDayUncertain && passport.attachments?.first?.fileName == "护照.pdf")
        #expect(try context.fetch(FetchDescriptor<Note>()).first?.isPinned == true)
    }

    @Test func attachmentsCanBeLeftOut() throws {
        // The context doesn't keep its container alive; hold it for the test.
        let library = try makeLibrary()
        let file = try Backup.make(from: library.mainContext, includeAttachments: false)
        #expect(file.attachments.isEmpty)
        #expect(file.entries.count == 2)
    }

    @Test func otherFilesAreRefused() throws {
        #expect(throws: BackupError.notABackup) { try Backup.read(Data(#"{"hello": 1}"#.utf8)) }
        #expect(throws: BackupError.newerVersion) {
            try Backup.read(Data(#"{"format": "ramble-backup", "version": 99}"#.utf8))
        }
    }
}

@MainActor
struct LedgerCSVTests {
    @Test func exportIsExcelFriendly() throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let context = container.mainContext
        let food = LedgerCategory(name: "餐饮", kind: .expense, symbol: "fork.knife", colorHex: "#FF9500")
        let coffee = LedgerCategory(name: "咖啡", kind: .expense, symbol: "cup.and.saucer", colorHex: "#A2845E")
        coffee.parent = food
        context.insert(food)
        context.insert(coffee)
        let entry = LedgerEntry(kind: .expense, amount: 28, currencyCode: "CNY", date: DraftParsing.date("2026-10-12", time: "08:30")!,
                                note: "拿铁, \"大杯\"")
        context.insert(entry)
        entry.category = coffee

        let data = LedgerCSV.export([entry])
        #expect(data.starts(with: [0xEF, 0xBB, 0xBF]))
        let text = try #require(LedgerCSV.decode(data))
        let rows = LedgerCSV.rows(text)
        #expect(rows[0] == LedgerCSV.exportHeader)
        #expect(rows[1] == ["2026-10-12 08:30", "支出", "28", "CNY", "餐饮", "咖啡", "", "", "拿铁, \"大杯\"", "手动"])
    }

    @Test func quotedFieldsKeepCommasAndLineBreaks() {
        let rows = LedgerCSV.rows("a,b,c\r\n1,\"x, y\",\"two\nlines\"\n\n2,\"say \"\"hi\"\"\",z")
        #expect(rows == [["a", "b", "c"], ["1", "x, y", "two\nlines"], ["2", "say \"hi\"", "z"]])
        #expect(LedgerCSV.rows("日期\t金额\n2026-10-01\t35") == [["日期", "金额"], ["2026-10-01", "35"]])
    }

    /// WeChat Pay's statement: account details above the header, "¥" amounts, "/" for neutral rows.
    @Test func weChatStatement() throws {
        let text = """
        微信支付账单明细,,,,,,,,,,
        微信昵称：[某人],,,,,,,,,,
        起始时间：[2026-10-01 00:00:00] 终止时间：[2026-10-13 23:59:59],,,,,,,,,,
        ----------------------微信支付账单明细列表--------------------,,,,,,,,,,
        交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态,交易单号,商户单号,备注
        2026-10-12 12:30:15,商户消费,兰州拉面,牛肉面,支出,¥22.00,零钱,支付成功,1001,2001,/
        2026-10-11 09:00:00,转账,张三,/,收入,¥500.00,零钱,已收钱,1002,/,/
        2026-10-10 18:00:00,零钱提现,招商银行,/,/,¥100.00,招商银行,提现已到账,1003,/,/
        """
        let table = try #require(LedgerCSV.Table(LedgerCSV.rows(text)))
        let mapping = table.guessedMapping()
        #expect(table.header[mapping[.date]!] == "交易时间")
        #expect(table.header[mapping[.amount]!] == "金额(元)")
        #expect(table.header[mapping[.kind]!] == "收/支")
        #expect(table.header[mapping[.counterparty]!] == "交易对方")
        #expect(table.header[mapping[.item]!] == "商品")
        #expect(table.header[mapping[.account]!] == "支付方式")
        let results = table.rows.map { LedgerCSV.read($0, mapping: mapping) }
        let noodle = try results[0].get()
        #expect(noodle.kind == .expense && noodle.amount == 22 && noodle.note == "兰州拉面 · 牛肉面")
        let transfer = try results[1].get()
        #expect(transfer.kind == .income && transfer.note == "张三")
        #expect(results[2] == .failure(.skipped))
    }

    /// Alipay writes GB18030 and puts the type in "收/支".
    @Test func alipayStatementInGB18030() throws {
        let text = """
        ------------------------支付宝交易记录明细查询------------------------
        交易时间,交易分类,交易对方,商品说明,收/支,金额,收/付款方式,交易状态,交易订单号,商家订单号,备注
        2026-10-09 08:12:00,餐饮美食,便利店,早餐,支出,12.50,花呗,交易成功,T1,M1,
        2026-10-08 10:00:00,投资理财,余额宝,收益发放,不计收支,0.35,,交易成功,T2,,
        """
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let data = try #require(text.data(using: gb18030))
        let decoded = try #require(LedgerCSV.decode(data))
        let table = try #require(LedgerCSV.Table(LedgerCSV.rows(decoded)))
        let mapping = table.guessedMapping()
        #expect(table.header[mapping[.category]!] == "交易分类")
        let breakfast = try LedgerCSV.read(table.rows[0], mapping: mapping).get()
        #expect(breakfast.category == "餐饮美食" && breakfast.amount == Decimal(string: "12.5") && breakfast.account == "花呗")
        #expect(LedgerCSV.read(table.rows[1], mapping: mapping) == .failure(.skipped))
    }

    /// A bookkeeping app's export with signed amounts and two category levels.
    @Test func signedAmountsWithoutATypeColumn() throws {
        let text = "日期,一级分类,二级分类,金额,账户,备注\n2026/10/3,餐饮,早餐,-8.5,现金,包子\n2026/10/5,工资,,12000,储蓄卡,\n2026/10/6,交通,,-4,现金,地铁"
        let table = try #require(LedgerCSV.Table(LedgerCSV.rows(text)))
        let mapping = table.guessedMapping()
        #expect(mapping[.subcategory] == 2 && mapping[.category] == 1)
        let signed = LedgerCSV.usesSignedAmounts(table.rows, mapping: mapping)
        #expect(signed)
        let rows = try table.rows.map { try LedgerCSV.read($0, mapping: mapping, signedAmounts: signed).get() }
        #expect(rows.map(\.kind) == [.expense, .income, .expense])
        #expect(rows[0].subcategory == "早餐" && rows[0].amount == Decimal(string: "8.5"))
    }

    @Test func amountsAndDatesInCommonShapes() {
        #expect(LedgerCSV.parseAmount("¥1,234.50") == Decimal(string: "1234.5"))
        #expect(LedgerCSV.parseAmount("（35.00）") == -35)
        #expect(LedgerCSV.parseAmount("35元") == 35)
        #expect(LedgerCSV.parseAmount("abc") == nil)
        #expect(LedgerCSV.parseDate("2026年10月3日") == DraftParsing.date("2026-10-03", time: "00:00"))
        #expect(LedgerCSV.parseDate("2026/10/3 9:05") == DraftParsing.date("2026-10-03", time: "09:05"))
        #expect(LedgerCSV.parseDate("2026-10-03 09:05:00\t") == DraftParsing.date("2026-10-03", time: "09:05"))
        #expect(LedgerCSV.parseDate("下周三") == nil)
    }

    @Test func importMatchesCategoriesAndSkipsWhatsAlreadyThere() throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let context = container.mainContext
        let food = LedgerCategory(name: "餐饮", kind: .expense, symbol: "fork.knife", colorHex: "#FF9500", seedKey: "food")
        let breakfast = LedgerCategory(name: "早餐", kind: .expense, symbol: "sun.max", colorHex: "#FF9500")
        breakfast.parent = food
        let other = LedgerCategory(name: "其他", kind: .expense, symbol: "ellipsis.circle", colorHex: "#6E6E73", seedKey: "other-expense")
        let cash = Account(name: "现金", kind: .cash)
        [food, breakfast, other].forEach(context.insert)
        context.insert(cash)
        let day = DraftParsing.date("2026-10-03", time: "08:00")!
        context.insert(LedgerEntry(kind: .expense, amount: 4, currencyCode: "CNY", date: day.addingTimeInterval(3600), note: "地铁"))
        try context.save()

        let rows = [
            LedgerCSV.Row(date: day, kind: .expense, amount: Decimal(string: "8.5")!, currency: nil, category: "餐饮", subcategory: "早餐", account: "现金", note: "包子"),
            LedgerCSV.Row(date: day.addingTimeInterval(3600), kind: .expense, amount: 4, currency: nil, category: "交通", subcategory: "", account: "", note: "地铁"),
            LedgerCSV.Row(date: day.addingTimeInterval(7200), kind: .expense, amount: 60, currency: nil, category: "宠物", subcategory: "", account: "", note: "猫粮"),
            LedgerCSV.Row(date: day.addingTimeInterval(9000), kind: .expense, amount: 3, currency: nil, category: "", subcategory: "", account: "", note: ""),
        ]
        let result = try LedgerCSV.importRows(rows, options: .init(), into: context)
        #expect(result == .init(imported: 3, duplicates: 1, newCategories: ["宠物"]))

        let entries = try context.fetch(FetchDescriptor<LedgerEntry>())
        #expect(entries.count == 4)
        let bun = try #require(entries.first { $0.note == "包子" })
        #expect(bun.category === breakfast && bun.account === cash && bun.source == .imported)
        #expect(entries.first { $0.note == "猫粮" }?.category?.name == "宠物")
        #expect(entries.first { $0.amount == 3 }?.category === other)

        // No category, but the merchant gives it away; a near-name joins the existing category.
        let food2 = try LedgerCSV.importRows([
            LedgerCSV.Row(date: day.addingTimeInterval(20_000), kind: .expense, amount: 9, currency: nil, category: "", subcategory: "", account: "", note: "瑞幸咖啡 · 生椰拿铁"),
            LedgerCSV.Row(date: day.addingTimeInterval(30_000), kind: .expense, amount: 30, currency: nil, category: "餐饮美食", subcategory: "", account: "", note: "便利店"),
        ], options: .init(), into: context)
        #expect(food2.imported == 2 && food2.newCategories.isEmpty)
        #expect(try context.fetch(FetchDescriptor<LedgerEntry>()).filter { $0.category === food }.count == 2)

        // Importing the same rows again adds nothing.
        #expect(try LedgerCSV.importRows(rows, options: .init(), into: context).imported == 0)
    }
}
