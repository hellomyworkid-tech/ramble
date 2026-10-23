import Foundation
import SwiftData

/// The whole library as one JSON file: every record, how they link up, and (optionally) the
/// photos and files attached. Restoring replaces everything on the phone with what's in it.
nonisolated struct BackupFile: Codable {
    static let formatName = "ramble-backup"
    static let currentVersion = 1

    var format = BackupFile.formatName
    var version = BackupFile.currentVersion
    var createdAt: Date
    var baseCurrency: String
    var accounts: [AccountRecord] = []
    var categories: [CategoryRecord] = []
    var entries: [EntryRecord] = []
    var budgets: [BudgetRecord] = []
    var bills: [BillRecord] = []
    /// Absent from backups made before 应收应付 existed.
    var outstandings: [OutstandingRecord]?
    var expiries: [ExpiryRecord] = []
    var tasks: [TaskRecord] = []
    var notes: [NoteRecord] = []
    var noteEntries: [NoteEntryRecord] = []
    var attachments: [AttachmentRecord] = []

    struct AccountRecord: Codable {
        var id: String, name: String, kind: String, currencyCode: String, initialBalance: Decimal
        var creditLimit: Decimal?, statementDay: Int?, paymentDueDay: Int?
        var sortOrder: Int, isArchived: Bool, createdAt: Date
    }

    struct CategoryRecord: Codable {
        var id: String, name: String, kind: String, symbol: String, colorHex: String, sortOrder: Int
        var seedKey: String?, parent: String?
    }

    struct EntryRecord: Codable {
        var id: String, kind: String, amount: Decimal, currencyCode: String, rateToBase: Decimal
        var date: Date, note: String, source: String, createdAt: Date
        var account: String?, toAccount: String?, category: String?, bill: String?
        var outstanding: String?
    }

    struct BudgetRecord: Codable {
        var amount: Decimal, createdAt: Date, category: String?
    }

    struct BillRecord: Codable {
        var id: String, name: String, kind: String, amount: Decimal, isAmountEstimated: Bool, currencyCode: String
        var nextDueDate: Date, recurrence: Data?, reminderRules: Data?, autoRecord: Bool, isActive: Bool
        var note: String, lastPaidAt: Date?, createdAt: Date
        var account: String?, creditAccount: String?, category: String?
    }

    struct OutstandingRecord: Codable {
        var id: String, direction: String, title: String, counterparty: String, amount: Decimal, currencyCode: String
        var dueDate: Date?, note: String, createdAt: Date, account: String?, category: String?
    }

    struct ExpiryRecord: Codable {
        var id: String, name: String, kind: String, expiryDate: Date, isDayUncertain: Bool, reminderRules: Data?
        var renewalMonths: Int, note: String, isArchived: Bool, createdAt: Date
    }

    struct TaskRecord: Codable {
        var id: String, title: String, notes: String, dueDate: Date?, hasDueTime: Bool, priority: Int, listName: String
        var isCompleted: Bool, completedAt: Date?, createdAt: Date, recurrence: Data?, reminderMinutes: [Int]
        var subtasks: [SubtaskRecord], sourceEntry: String?, sourceQuote: String
    }

    struct SubtaskRecord: Codable {
        var title: String, isDone: Bool, order: Int
    }

    struct NoteRecord: Codable {
        var id: String, title: String, isPinned: Bool, createdAt: Date, updatedAt: Date
    }

    struct NoteEntryRecord: Codable {
        var id: String, note: String?, text: String, date: Date, createdAt: Date, editedAt: Date?
        var source: String, isKeyPoint: Bool, highlights: Data?
    }

    struct AttachmentRecord: Codable {
        var kind: String, imageData: Data?, fileData: Data?, thumbnailData: Data?, fileName: String
        var contentTypeID: String, byteCount: Int, recognizedText: String, createdAt: Date
        var entry: String?, expiry: String?, noteEntry: String?
    }

    /// "128 条账目、12 条待办…" for the restore confirmation.
    var summary: String {
        var parts: [String] = []
        if !entries.isEmpty { parts.append(String(localized: "\(entries.count) 条账目")) }
        if !tasks.isEmpty { parts.append(String(localized: "\(tasks.count) 条待办")) }
        if !notes.isEmpty { parts.append(String(localized: "\(notes.count) 本笔记")) }
        if !bills.isEmpty { parts.append(String(localized: "\(bills.count) 个账单")) }
        if let outstandings, !outstandings.isEmpty { parts.append(String(localized: "\(outstandings.count) 笔应收应付")) }
        if !expiries.isEmpty { parts.append(String(localized: "\(expiries.count) 个到期提醒")) }
        if !attachments.isEmpty { parts.append(String(localized: "\(attachments.count) 个附件")) }
        return parts.isEmpty ? String(localized: "没有记录") : parts.joined(separator: "、")
    }
}

enum BackupError: LocalizedError {
    case notABackup
    case newerVersion

    var errorDescription: String? {
        switch self {
        case .notABackup: String(localized: "这不是随口记的备份文件。")
        case .newerVersion: String(localized: "这个备份来自更新版本的随口记，请先更新 App。")
        }
    }
}

enum Backup {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// Reads a backup file, checking it's one this version can restore.
    static func read(_ data: Data) throws -> BackupFile {
        struct Header: Decodable { var format: String?, version: Int? }
        guard let header = try? JSONDecoder().decode(Header.self, from: data), header.format == BackupFile.formatName else {
            throw BackupError.notABackup
        }
        guard (header.version ?? 0) <= BackupFile.currentVersion else { throw BackupError.newerVersion }
        return try JSONDecoder().decode(BackupFile.self, from: data)
    }

    // MARK: Export

    static func make(from context: ModelContext, includeAttachments: Bool = true, now: Date = .now) throws -> BackupFile {
        var ids: [PersistentIdentifier: String] = [:]
        func id(_ model: (any PersistentModel)?) -> String? {
            guard let model else { return nil }
            if let existing = ids[model.persistentModelID] { return existing }
            let new = String(ids.count + 1)
            ids[model.persistentModelID] = new
            return new
        }
        func all<T: PersistentModel>(_ type: T.Type) throws -> [T] { try context.fetch(FetchDescriptor<T>()) }

        var file = BackupFile(createdAt: now, baseCurrency: LedgerSummary.baseCurrency)
        file.accounts = try all(Account.self).map {
            .init(id: id($0)!, name: $0.name, kind: $0.kindRaw, currencyCode: $0.currencyCode, initialBalance: $0.initialBalance,
                  creditLimit: $0.creditLimit, statementDay: $0.statementDay, paymentDueDay: $0.paymentDueDay,
                  sortOrder: $0.sortOrder, isArchived: $0.isArchived, createdAt: $0.createdAt)
        }
        file.categories = try all(LedgerCategory.self).map {
            .init(id: id($0)!, name: $0.name, kind: $0.kindRaw, symbol: $0.symbol, colorHex: $0.colorHex, sortOrder: $0.sortOrder,
                  seedKey: $0.seedKey, parent: id($0.parent))
        }
        file.bills = try all(Bill.self).map {
            .init(id: id($0)!, name: $0.name, kind: $0.kindRaw, amount: $0.amount, isAmountEstimated: $0.isAmountEstimated,
                  currencyCode: $0.currencyCode, nextDueDate: $0.nextDueDate, recurrence: $0.recurrenceData,
                  reminderRules: $0.reminderRulesData, autoRecord: $0.autoRecord, isActive: $0.isActive, note: $0.note,
                  lastPaidAt: $0.lastPaidAt, createdAt: $0.createdAt, account: id($0.account),
                  creditAccount: id($0.creditAccount), category: id($0.category))
        }
        file.outstandings = try all(Outstanding.self).map {
            .init(id: id($0)!, direction: $0.directionRaw, title: $0.title, counterparty: $0.counterparty, amount: $0.amount,
                  currencyCode: $0.currencyCode, dueDate: $0.dueDate, note: $0.note, createdAt: $0.createdAt,
                  account: id($0.account), category: id($0.category))
        }
        file.entries = try all(LedgerEntry.self).map {
            .init(id: id($0)!, kind: $0.kindRaw, amount: $0.amount, currencyCode: $0.currencyCode, rateToBase: $0.rateToBase,
                  date: $0.date, note: $0.note, source: $0.sourceRaw, createdAt: $0.createdAt, account: id($0.account),
                  toAccount: id($0.toAccount), category: id($0.category), bill: id($0.bill), outstanding: id($0.outstanding))
        }
        file.budgets = try all(Budget.self).map { .init(amount: $0.amount, createdAt: $0.createdAt, category: id($0.category)) }
        file.expiries = try all(ExpiryItem.self).map {
            .init(id: id($0)!, name: $0.name, kind: $0.kindRaw, expiryDate: $0.expiryDate, isDayUncertain: $0.isDayUncertain,
                  reminderRules: $0.reminderRulesData, renewalMonths: $0.renewalMonths, note: $0.note,
                  isArchived: $0.isArchived, createdAt: $0.createdAt)
        }
        file.notes = try all(Note.self).map {
            .init(id: id($0)!, title: $0.title, isPinned: $0.isPinned, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }
        file.noteEntries = try all(NoteEntry.self).map {
            .init(id: id($0)!, note: id($0.note), text: $0.text, date: $0.date, createdAt: $0.createdAt, editedAt: $0.editedAt,
                  source: $0.sourceRaw, isKeyPoint: $0.isKeyPoint, highlights: $0.highlightsData)
        }
        file.tasks = try all(TaskItem.self).map {
            .init(id: id($0)!, title: $0.title, notes: $0.notes, dueDate: $0.dueDate, hasDueTime: $0.hasDueTime,
                  priority: $0.priorityRaw, listName: $0.listName, isCompleted: $0.isCompleted, completedAt: $0.completedAt,
                  createdAt: $0.createdAt, recurrence: $0.recurrenceData, reminderMinutes: $0.reminderMinutes,
                  subtasks: $0.sortedSubtasks.map { .init(title: $0.title, isDone: $0.isDone, order: $0.order) },
                  sourceEntry: id($0.sourceEntry), sourceQuote: $0.sourceQuote)
        }
        if includeAttachments {
            file.attachments = try all(Attachment.self).map {
                .init(kind: $0.kindRaw, imageData: $0.imageData, fileData: $0.fileData, thumbnailData: $0.thumbnailData,
                      fileName: $0.fileName, contentTypeID: $0.contentTypeID, byteCount: $0.byteCount,
                      recognizedText: $0.recognizedText, createdAt: $0.createdAt, entry: id($0.entry),
                      expiry: id($0.expiry), noteEntry: id($0.noteEntry))
            }
        }
        return file
    }

    /// Bytes the attachments would add to a backup, to show before exporting.
    static func attachmentBytes(in context: ModelContext) -> Int64 {
        let attachments = (try? context.fetch(FetchDescriptor<Attachment>())) ?? []
        return attachments.reduce(Int64(0)) { $0 + Int64($1.byteCount + ($1.thumbnailData?.count ?? 0)) }
    }

    // MARK: Restore

    /// Replaces everything with the backup's records, in one save: if anything fails, nothing changes.
    static func restore(_ file: BackupFile, into context: ModelContext) throws {
        do {
            try deleteEverything(in: context)

            var accounts: [String: Account] = [:]
            for record in file.accounts {
                let account = Account(name: record.name, kind: AccountKind(rawValue: record.kind) ?? .other,
                                      currencyCode: record.currencyCode, initialBalance: record.initialBalance,
                                      sortOrder: record.sortOrder)
                account.kindRaw = record.kind
                account.creditLimit = record.creditLimit
                account.statementDay = record.statementDay
                account.paymentDueDay = record.paymentDueDay
                account.isArchived = record.isArchived
                account.createdAt = record.createdAt
                context.insert(account)
                accounts[record.id] = account
            }

            var categories: [String: LedgerCategory] = [:]
            for record in file.categories {
                let category = LedgerCategory(name: record.name, kind: CategoryKind(rawValue: record.kind) ?? .expense,
                                              symbol: record.symbol, colorHex: record.colorHex, sortOrder: record.sortOrder,
                                              seedKey: record.seedKey)
                context.insert(category)
                categories[record.id] = category
            }
            for record in file.categories {
                if let parent = record.parent { categories[record.id]?.parent = categories[parent] }
            }

            var bills: [String: Bill] = [:]
            for record in file.bills {
                let bill = Bill(name: record.name, kind: BillKind(rawValue: record.kind) ?? .other, amount: record.amount,
                                currencyCode: record.currencyCode, nextDueDate: record.nextDueDate)
                bill.kindRaw = record.kind
                bill.isAmountEstimated = record.isAmountEstimated
                bill.recurrenceData = record.recurrence
                bill.reminderRulesData = record.reminderRules
                bill.autoRecord = record.autoRecord
                bill.isActive = record.isActive
                bill.note = record.note
                bill.lastPaidAt = record.lastPaidAt
                bill.createdAt = record.createdAt
                context.insert(bill)
                bill.account = record.account.flatMap { accounts[$0] }
                bill.creditAccount = record.creditAccount.flatMap { accounts[$0] }
                bill.category = record.category.flatMap { categories[$0] }
                bills[record.id] = bill
            }

            var outstandings: [String: Outstanding] = [:]
            for record in file.outstandings ?? [] {
                let item = Outstanding(direction: OutstandingDirection(rawValue: record.direction) ?? .receivable, title: record.title,
                                       counterparty: record.counterparty, amount: record.amount, currencyCode: record.currencyCode,
                                       dueDate: record.dueDate)
                item.note = record.note
                item.createdAt = record.createdAt
                context.insert(item)
                item.account = record.account.flatMap { accounts[$0] }
                item.category = record.category.flatMap { categories[$0] }
                outstandings[record.id] = item
            }

            var entries: [String: LedgerEntry] = [:]
            for record in file.entries {
                let entry = LedgerEntry(kind: EntryKind(rawValue: record.kind) ?? .expense, amount: record.amount,
                                        currencyCode: record.currencyCode, date: record.date, note: record.note,
                                        source: EntrySource(rawValue: record.source) ?? .manual)
                entry.kindRaw = record.kind
                entry.sourceRaw = record.source
                entry.rateToBase = record.rateToBase
                entry.createdAt = record.createdAt
                context.insert(entry)
                entry.account = record.account.flatMap { accounts[$0] }
                entry.toAccount = record.toAccount.flatMap { accounts[$0] }
                entry.category = record.category.flatMap { categories[$0] }
                entry.bill = record.bill.flatMap { bills[$0] }
                entry.outstanding = record.outstanding.flatMap { outstandings[$0] }
                entries[record.id] = entry
            }

            for record in file.budgets {
                let budget = Budget(amount: record.amount)
                budget.createdAt = record.createdAt
                context.insert(budget)
                budget.category = record.category.flatMap { categories[$0] }
            }

            var expiries: [String: ExpiryItem] = [:]
            for record in file.expiries {
                let item = ExpiryItem(name: record.name, kind: ExpiryKind(rawValue: record.kind) ?? .other,
                                      expiryDate: record.expiryDate, isDayUncertain: record.isDayUncertain)
                item.kindRaw = record.kind
                item.reminderRulesData = record.reminderRules
                item.renewalMonths = record.renewalMonths
                item.note = record.note
                item.isArchived = record.isArchived
                item.createdAt = record.createdAt
                context.insert(item)
                expiries[record.id] = item
            }

            var notes: [String: Note] = [:]
            for record in file.notes {
                let note = Note(title: record.title)
                note.isPinned = record.isPinned
                note.createdAt = record.createdAt
                note.updatedAt = record.updatedAt
                context.insert(note)
                notes[record.id] = note
            }

            var noteEntries: [String: NoteEntry] = [:]
            for record in file.noteEntries {
                let entry = NoteEntry(text: record.text, date: record.date, source: EntrySource(rawValue: record.source) ?? .manual)
                entry.sourceRaw = record.source
                entry.createdAt = record.createdAt
                entry.editedAt = record.editedAt
                entry.isKeyPoint = record.isKeyPoint
                entry.highlightsData = record.highlights
                context.insert(entry)
                entry.note = record.note.flatMap { notes[$0] }
                noteEntries[record.id] = entry
            }

            for record in file.tasks {
                let task = TaskItem(title: record.title, dueDate: record.dueDate, hasDueTime: record.hasDueTime,
                                    priority: TaskPriority(rawValue: record.priority) ?? .none, listName: record.listName)
                task.notes = record.notes
                task.isCompleted = record.isCompleted
                task.completedAt = record.completedAt
                task.createdAt = record.createdAt
                task.recurrenceData = record.recurrence
                task.reminderMinutes = record.reminderMinutes
                task.sourceQuote = record.sourceQuote
                context.insert(task)
                task.sourceEntry = record.sourceEntry.flatMap { noteEntries[$0] }
                for subtask in record.subtasks {
                    let item = Subtask(title: subtask.title, order: subtask.order)
                    item.isDone = subtask.isDone
                    context.insert(item)
                    item.task = task
                }
            }

            for record in file.attachments {
                let attachment: Attachment
                if let fileData = record.fileData {
                    attachment = Attachment(fileData: fileData, fileName: record.fileName, contentTypeID: record.contentTypeID,
                                            thumbnailData: record.thumbnailData, recognizedText: record.recognizedText)
                } else if let imageData = record.imageData {
                    attachment = Attachment(imageData: imageData, thumbnailData: record.thumbnailData ?? Data(),
                                            recognizedText: record.recognizedText)
                    attachment.fileName = record.fileName
                    attachment.contentTypeID = record.contentTypeID
                } else {
                    continue
                }
                attachment.kindRaw = record.kind
                attachment.byteCount = record.byteCount
                attachment.createdAt = record.createdAt
                context.insert(attachment)
                attachment.entry = record.entry.flatMap { entries[$0] }
                attachment.expiry = record.expiry.flatMap { expiries[$0] }
                attachment.noteEntry = record.noteEntry.flatMap { noteEntries[$0] }
            }

            try context.save()
            UserDefaults.standard.set(file.baseCurrency, forKey: AppSettings.baseCurrencyKey)
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func deleteEverything(in context: ModelContext) throws {
        func remove<T: PersistentModel>(_ type: T.Type) throws {
            for model in try context.fetch(FetchDescriptor<T>()) { context.delete(model) }
        }
        try remove(Attachment.self)
        try remove(Subtask.self)
        try remove(TaskItem.self)
        try remove(NoteEntry.self)
        try remove(Note.self)
        try remove(LedgerEntry.self)
        try remove(Budget.self)
        try remove(Bill.self)
        try remove(Outstanding.self)
        try remove(ExpiryItem.self)
        try remove(Account.self)
        try remove(LedgerCategory.self)
    }

    static func fileName(now: Date = .now) -> String {
        String(localized: "随口记备份 \(now.formatted(.iso8601.year().month().day()))")
    }
}
