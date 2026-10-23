import Foundation
import SwiftData
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Ramble

struct NoteModelTests {
    private let container = AppSchema.makeContainer(inMemory: true)

    @Test func entriesKeepTimeOrderAndBumpTheNote() throws {
        let context = container.mainContext
        let note = Note(title: "装修记录")
        context.insert(note)
        note.updatedAt = .distantPast
        let later = note.append("铺地板", date: Date(timeIntervalSince1970: 2_000), in: context)
        let earlier = note.append("定方案", date: Date(timeIntervalSince1970: 1_000), in: context)

        #expect(note.sortedEntries.map(\.text) == ["定方案", "铺地板"])
        #expect(note.latestEntry === later)
        #expect(note.updatedAt > .distantPast)
        #expect(earlier.note === note)
    }

    @Test func searchCoversTitleTextFilesAndRecognizedText() throws {
        let context = container.mainContext
        let note = Note(title: "家电")
        context.insert(note)
        let entry = note.append("空调装好了", in: context)
        let warranty = Ramble.Attachment(imageData: Data([1]), thumbnailData: Data([1]), recognizedText: "保修卡 三年整机保修")
        context.insert(warranty)
        warranty.noteEntry = entry
        let manual = Ramble.Attachment(fileData: Data([2]), fileName: "说明书.pdf", contentTypeID: "com.adobe.pdf", thumbnailData: nil)
        context.insert(manual)
        manual.noteEntry = entry

        #expect(note.matches("家电"))
        #expect(note.matches("空调"))
        #expect(note.matches("保修卡"))
        #expect(note.matches("说明书"))
        #expect(!note.matches("冰箱"))
    }

    @Test func sentencesSplitOnChineseAndWesternPunctuation() {
        #expect(Sentences.split("瓷砖到了。师傅说下周三铺砖！要买胶吗？\n记得拍照") ==
                ["瓷砖到了。", "师傅说下周三铺砖！", "要买胶吗？", "记得拍照"])
    }

    @Test func deletingAnEntryKeepsItsReminder() throws {
        let context = container.mainContext
        let note = Note(title: "体检")
        context.insert(note)
        let entry = note.append("三个月后复查。", in: context)
        let task = TaskItem(title: "复查")
        context.insert(task)
        task.sourceEntry = entry
        task.sourceQuote = "三个月后复查。"
        try context.save()

        context.delete(entry)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<TaskItem>()) == 1)
        #expect(task.sourceEntry == nil)
    }

    @Test func highlightsAndKeyPoints() throws {
        let context = container.mainContext
        let note = Note(title: "装修记录")
        context.insert(note)
        let entry = note.append("预算 12 万。木地板选橡木。下周三铺砖。", in: context)
        #expect(!entry.isImportant)
        #expect(note.importantCount == 0)

        entry.toggleHighlight("预算 12 万。")
        entry.toggleHighlight(" 下周三铺砖。 ")
        entry.toggleHighlight("预算 12 万。")
        #expect(entry.highlights == ["下周三铺砖。"])
        #expect(entry.isImportant)

        // Duplicates collapse; passages edited out of the text disappear.
        entry.highlights = ["木地板选橡木。", "木地板选橡木。", ""]
        #expect(entry.highlights == ["木地板选橡木。"])
        entry.text = "预算 12 万。下周三铺砖。"
        #expect(entry.highlights.isEmpty)
        #expect(!entry.isImportant)

        entry.isKeyPoint = true
        let plain = note.append("今天没什么进展。", in: context)
        #expect(note.importantCount == 1)
        #expect(!plain.isImportant)
    }

    @Test func reminderTitleComesFromTheSentence() {
        #expect(ReminderFromTextSheet.defaultTitle(from: "下周三可以铺砖。") == "下周三可以铺砖")
        // Long sentences stay whole: an ellipsis in the middle of a to-do is hard to edit.
        #expect(ReminderFromTextSheet.defaultTitle(from: String(repeating: "长", count: 40) + "。") == String(repeating: "长", count: 40))
    }
}

struct NoteCaptureTests {
    private let container = AppSchema.makeContainer(inMemory: true)

    /// "装修那边师傅说下周三能铺砖，今天买瓷砖花了三千二": a note entry, a reminder linked to its sentence, an expense.
    @Test func captureAppendsToTheNoteAndLinksTheReminder() throws {
        let context = container.mainContext
        SeedData.seedDefaultsIfNeeded(context)
        let renovation = Note(title: "装修记录")
        context.insert(renovation)
        let categories = try context.fetch(FetchDescriptor<LedgerCategory>())
        let accounts = try context.fetch(FetchDescriptor<Account>())

        let sentence = "师傅说水泥要养护 7 天，下周三可以铺砖。"
        var noteItem = ParsedItem()
        noteItem.type = "note"; noteItem.title = "装修记录"; noteItem.note = sentence + "\n今天买瓷砖花了 3,200 元。"
        var taskItem = ParsedItem()
        taskItem.type = "task"; taskItem.title = "铺砖"; taskItem.date = "2026-10-21"; taskItem.quote = sentence
        var expenseItem = ParsedItem()
        expenseItem.type = "expense"; expenseItem.title = "瓷砖"; expenseItem.amount = "3200"; expenseItem.category = "居住"

        var drafts = [noteItem, taskItem, expenseItem].map {
            CaptureDraft(item: $0, categories: categories, accounts: accounts, baseCurrency: "CNY")
        }
        for index in drafts.indices { drafts[index].linkExisting(bills: [], expiries: [], notes: [renovation]) }
        #expect(drafts[0].existingNote === renovation)
        #expect(drafts[0].problem == nil)

        let entries = drafts.filter { $0.kind == .note }.compactMap { $0.save(in: context, baseCurrency: "CNY")?.noteEntry }
        for draft in drafts where draft.kind != .note { draft.save(in: context, baseCurrency: "CNY", linking: entries) }
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<Note>()) == 1)
        #expect(renovation.entries?.count == 1)
        let task = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
        #expect(task.sourceEntry === entries.first)
        #expect(task.sourceQuote == sentence)
        #expect(try context.fetch(FetchDescriptor<LedgerEntry>()).first?.amount == 3200)
    }

    /// The note already reminds about 铺砖 on that day; saying it again shouldn't add a second one.
    @Test func repeatedReminderIsNotDuplicated() throws {
        let context = container.mainContext
        let renovation = Note(title: "装修记录")
        context.insert(renovation)
        let earlier = renovation.append("下周三可以铺砖。", in: context)
        let due = try #require(DraftParsing.date("2026-10-21"))
        let tiling = TaskItem(title: "铺砖", dueDate: due)
        context.insert(tiling)
        tiling.sourceEntry = earlier
        tiling.sourceQuote = "下周三可以铺砖。"
        let unrelated = TaskItem(title: "铺砖", dueDate: DraftParsing.date("2026-11-04"))
        context.insert(unrelated)
        try context.save()

        var item = ParsedItem()
        item.type = "task"; item.title = "铺砖"; item.date = "2026-10-21"; item.quote = "师傅说下周三可以铺砖。"
        var draft = CaptureDraft(item: item, categories: [], accounts: [], baseCurrency: "CNY")
        draft.linkExisting(bills: [], expiries: [], notes: [renovation], tasks: [tiling, unrelated])
        #expect(draft.existingTask === tiling)

        draft.save(in: context, baseCurrency: "CNY")
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<TaskItem>()) == 2)
        #expect(tiling.sourceEntry === earlier)

        draft.updatesExisting = false
        draft.save(in: context, baseCurrency: "CNY")
        #expect(try context.fetchCount(FetchDescriptor<TaskItem>()) == 3)
    }

    @Test func unknownNoteTitleCreatesANewNote() throws {
        let context = container.mainContext
        var item = ParsedItem()
        item.type = "note"; item.title = "孩子成长"; item.note = "今天第一次自己走了五步。"
        var draft = CaptureDraft(item: item, categories: [], accounts: [], baseCurrency: "CNY")
        draft.linkExisting(bills: [], expiries: [], notes: [])
        #expect(draft.existingNote == nil)

        let entry = draft.save(in: context, baseCurrency: "CNY")?.noteEntry
        #expect(entry?.note?.title == "孩子成长")
        #expect(entry?.source == .ai)
    }

    @Test func aNoteNeedsContent() {
        var item = ParsedItem()
        item.type = "note"; item.title = "装修记录"
        #expect(CaptureDraft(item: item, categories: [], accounts: [], baseCurrency: "CNY").problem == "缺少内容")
        #expect(!CaptureEngine.isUsable(ParsedCapture(items: [item])))
    }
}

struct NoteOrganizerTests {
    @Test func schemaIsStrictModeSafe() {
        func check(_ node: [String: Any]) {
            if node["type"] as? String == "object" {
                let properties = node["properties"] as? [String: Any] ?? [:]
                #expect(node["additionalProperties"] as? Bool == false)
                #expect(Set(node["required"] as? [String] ?? []) == Set(properties.keys))
                properties.values.compactMap { $0 as? [String: Any] }.forEach(check)
            }
            if let items = node["items"] as? [String: Any] { check(items) }
        }
        check(NoteOrganizer.schema.jsonSchema)
    }

    @Test func resultsThatDropTextOrInventDatesAreRejected() {
        let original = "嗯那个今天师傅来看了一下，说墙面要等干透才能刷漆，大概要一周，然后下周三可以开始铺砖"
        let good = OrganizedNote(cleanedText: "今天师傅来看了，说墙面要等干透才能刷漆，大概要一周。下周三可以开始铺砖。",
                                 reminders: [ReminderSuggestion(quote: "下周三可以开始铺砖。", title: "铺砖", date: "2026-10-21")])
        #expect(NoteOrganizer.isUsable(good, original: original))

        let tooShort = OrganizedNote(cleanedText: "铺砖。")
        #expect(!NoteOrganizer.isUsable(tooShort, original: original))

        var badDate = good
        badDate.reminders = [ReminderSuggestion(quote: "x", title: "铺砖", date: "下周三")]
        #expect(!NoteOrganizer.isUsable(badDate, original: original))
    }

    @Test func decodingToleratesMissingFields() throws {
        let decoded = try CloudClient.decode(OrganizedNote.self, from: #"{"cleanedText":"今天铺了一半。"}"#)
        #expect(decoded.cleanedText == "今天铺了一半。")
        #expect(decoded.reminders.isEmpty)
    }

    @Test func remindersTheNoteAlreadyHasAreDropped() throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let context = container.mainContext
        let note = Note(title: "装修记录")
        context.insert(note)
        let entry = note.append("下周三可以铺砖。", in: context)
        let due = try #require(DraftParsing.date("2026-10-21"))
        let task = TaskItem(title: "铺砖", dueDate: due)
        context.insert(task)
        task.sourceEntry = entry
        #expect(note.openReminderKeys == ["铺砖 2026-10-21"])

        let suggested = OrganizedNote(cleanedText: "下周三铺砖，周五买踢脚线。", reminders: [
            ReminderSuggestion(quote: "下周三铺砖", title: "铺砖", date: "2026-10-21"),
            ReminderSuggestion(quote: "周五买踢脚线", title: "买踢脚线", date: "2026-10-16"),
        ])
        let kept = NoteOrganizer.droppingKnown(suggested, existing: note.openReminderKeys)
        #expect(kept.reminders.map(\.title) == ["买踢脚线"])
        #expect(NoteOrganizer.instructions(noteTitle: "装修记录", existingReminders: note.openReminderKeys, now: .now)
            .contains("铺砖 2026-10-21"))

        task.isCompleted = true
        #expect(note.openReminderKeys.isEmpty)
    }

    @Test func instructionsNameTheNote() {
        #expect(NoteOrganizer.instructions(noteTitle: "装修记录", now: .now).contains("\"装修记录\""))
        #expect(NoteOrganizer.instructions(noteTitle: "", now: .now).contains("an untitled note"))
    }
}

struct DocumentAttachmentTests {
    private let container = AppSchema.makeContainer(inMemory: true)

    @Test func documentsSyncWithTheirFileDetails() throws {
        let context = container.mainContext
        let note = Note(title: "合同")
        context.insert(note)
        let entry = note.append("租房合同签好了", in: context)
        let draft = DraftAttachment(kind: .document, newData: Data("hello".utf8), fileName: "租房合同.pdf", contentType: "com.adobe.pdf")
        DraftAttachment.sync([draft], replacing: entry.attachments, in: context) { $0.noteEntry = entry }
        try context.save()

        let stored = try #require(entry.attachments?.first)
        #expect(stored.kind == .document)
        #expect(stored.fileName == "租房合同.pdf")
        #expect(stored.data == Data("hello".utf8))
        #expect(stored.imageData == nil)
        #expect(stored.byteCount == 5)
    }

    @Test func textIsReadFromPDFsAndTextFiles() async throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 300))
        let pdf = renderer.pdfData { context in
            context.beginPage()
            ("Warranty 3 years" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
        }
        let pdfText = await AttachmentImporter.extractText(from: pdf, kind: .document, contentType: "com.adobe.pdf")
        #expect(pdfText.contains("Warranty"))

        let plain = await AttachmentImporter.extractText(from: Data("密码 1234".utf8), kind: .document, contentType: "public.plain-text")
        #expect(plain == "密码 1234")
    }

    @Test func pdfsGetAFirstPageThumbnail() throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 300))
        let pdf = renderer.pdfData { context in context.beginPage() }
        #expect(AttachmentImporter.thumbnail(for: pdf, type: .pdf) != nil)
        #expect(AttachmentImporter.thumbnail(for: Data("x".utf8), type: .plainText) == nil)
    }
}
