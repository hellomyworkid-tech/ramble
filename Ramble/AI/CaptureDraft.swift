import SwiftData
import SwiftUI

enum DraftKind: String, CaseIterable, Identifiable {
    case task, expense, income, transfer, bill, expiry, note, receivable, payable

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .task: LocalizedStringResource("kind.task", defaultValue: "待办")
        case .expense: "支出"
        case .income: "收入"
        case .transfer: "转账"
        case .bill: LocalizedStringResource("kind.bill", defaultValue: "账单")
        case .expiry: LocalizedStringResource("kind.expiry", defaultValue: "到期")
        case .note: LocalizedStringResource("kind.note", defaultValue: "笔记")
        case .receivable: "应收"
        case .payable: "应付"
        }
    }

    var symbol: String {
        switch self {
        case .task: "checkmark"
        case .expense: "creditcard"
        case .income: "arrow.down.circle"
        case .transfer: "arrow.left.arrow.right"
        case .bill: "calendar"
        case .expiry: "person.text.rectangle"
        case .note: "note.text"
        case .receivable: "arrow.down.left.circle"
        case .payable: "arrow.up.right.circle"
        }
    }

    var color: Color {
        switch self {
        case .task: ModuleColor.tasks
        case .expense, .income, .transfer, .receivable, .payable: ModuleColor.money
        case .bill: ModuleColor.bills
        case .expiry: ModuleColor.expiry
        case .note: ModuleColor.notes
        }
    }

    var hasAmount: Bool { [.expense, .income, .transfer, .bill, .receivable, .payable].contains(self) }

    var outstandingDirection: OutstandingDirection? {
        switch self {
        case .receivable: .receivable
        case .payable: .payable
        default: nil
        }
    }
}

/// What saving a draft produced (or updated).
enum SavedRecord {
    case noteEntry(NoteEntry)
    case task(TaskItem)
    case ledger(LedgerEntry)
    case bill(Bill)
    case expiry(ExpiryItem)
    case outstanding(Outstanding)

    var noteEntry: NoteEntry? {
        if case .noteEntry(let entry) = self { entry } else { nil }
    }

    /// Hangs a file on the record, if it keeps files (tasks and bills don't).
    func attach(_ attachment: Attachment) -> Bool {
        switch self {
        case .noteEntry(let entry): attachment.noteEntry = entry
        case .ledger(let entry): attachment.entry = entry
        case .expiry(let item): attachment.expiry = item
        case .task, .bill, .outstanding: return false
        }
        return true
    }

    var keepsFiles: Bool {
        switch self {
        case .noteEntry, .ledger, .expiry: true
        case .task, .bill, .outstanding: false
        }
    }
}

/// One AI-parsed record the person reviews (and can edit) before it is saved.
struct CaptureDraft: Identifiable {
    let id = UUID()
    var kind: DraftKind
    var title: String
    var amountText = ""
    var amountIsApproximate = false
    var currencyCode: String
    var category: LedgerCategory?
    var account: Account?
    var toAccount: Account?
    var date: Date?
    var hasTime = false
    var dateIsApproximate = false
    var recurrence: Recurrence?
    var reminderRules: [ReminderRule] = []
    var priority: TaskPriority = .none
    var listName = ""
    var billKind: BillKind = .other
    var expiryKind: ExpiryKind = .other
    var note = ""
    /// Fields the AI guessed ("amount", "date", …); cleared as the person edits them.
    var uncertain: Set<String> = []
    /// A bill or expiry item this draft refers to. Saving updates it instead of
    /// creating a duplicate, unless the person chooses to add a new one.
    var existingBill: Bill?
    var existingExpiry: ExpiryItem?
    /// For notes: the note this text is appended to.
    var existingNote: Note?
    /// For notes: an entry this text is added to instead of starting a new one
    /// (a summary of files that are already saved there).
    var appendsToEntry: NoteEntry?
    /// For tasks: an open to-do with the same name on the same day, often one
    /// a note already holds when the person repeats themselves.
    var existingTask: TaskItem?
    var updatesExisting = true
    /// For tasks: the note sentence this reminder came from.
    var quote = ""
    /// For notes: mark the entry as a key point (「给这条标记一下重点」).
    var isKeyPoint = false
    /// 应收应付: who owes or is owed.
    var counterparty = ""

    var existingName: String? {
        existingBill?.name ?? existingExpiry?.name ?? existingNote?.displayTitle ?? existingTask?.title
    }

    /// Links bills, expiry items, notes and to-dos to records that already exist.
    mutating func linkExisting(bills: [Bill], expiries: [ExpiryItem], notes: [Note] = [], tasks: [TaskItem] = []) {
        switch kind {
        case .task:
            guard let date else { break }
            let sameDay = tasks.filter { task in
                !task.isCompleted && task.dueDate.map { Calendar.current.isDate($0, inSameDayAs: date) } == true
            }
            existingTask = DraftParsing.bestMatch(title, in: sameDay, name: \.title)
        case .bill:
            let active = bills.filter(\.isActive)
            existingBill = DraftParsing.bestMatch(title, in: active, name: \.name)
            if existingBill == nil, billKind != .other {
                let sameKind = active.filter { $0.kind == billKind }
                if sameKind.count == 1 { existingBill = sameKind.first }
            }
        case .expiry:
            existingExpiry = DraftParsing.bestMatch(title, in: expiries.filter { !$0.isArchived }, name: \.name)
        case .note:
            existingNote = DraftParsing.bestMatch(title, in: notes, name: \.title)
        default:
            break
        }
    }

    var amount: Decimal? {
        guard let value = Decimal(userInput: amountText), value > 0 else { return nil }
        return value
    }

    /// Why this draft can't be saved yet, if anything.
    var problem: String? {
        if kind == .note {
            if note.trimmed.isEmpty { return String(localized: "缺少内容") }
            if title.trimmed.isEmpty && !(updatesExisting && existingNote != nil) && appendsToEntry == nil {
                return String(localized: "缺少笔记名称")
            }
            return nil
        }
        if title.trimmed.isEmpty { return String(localized: "缺少名称") }
        if kind.hasAmount, amount == nil { return String(localized: "缺少金额") }
        if [.bill, .expiry].contains(kind), date == nil { return String(localized: "缺少日期") }
        if kind == .transfer, account == nil || toAccount == nil { return String(localized: "缺少转出或转入账户") }
        return nil
    }

    var uncertainCount: Int { uncertain.count }
}

extension CaptureDraft {
    init(item: ParsedItem, categories: [LedgerCategory], accounts: [Account], baseCurrency: String, now: Date = .now) {
        let calendar = Calendar.current
        kind = DraftKind(rawValue: item.type) ?? .task
        // Money that's owed rather than moved, whichever model read it: 「张三还欠我两千」.
        let said = [item.quote, item.note, item.title].joined(separator: " ")
        if kind == .expense || kind == .income, let direction = OutstandingCues.direction(in: said) {
            kind = direction == .receivable ? .receivable : .payable
        }
        if let direction = kind.outstandingDirection {
            counterparty = item.counterparty.trimmed.isEmpty
                ? OutstandingCues.counterparty(in: said, direction: direction) : item.counterparty.trimmed
        }
        title = item.title.trimmed
        amountText = Decimal(userInput: item.amount)?.inputText ?? ""
        amountIsApproximate = item.amountIsApproximate
        currencyCode = item.currency.count == 3 ? item.currency.uppercased() : baseCurrency
        note = item.note.trimmed
        quote = item.quote.trimmed
        listName = item.listName.trimmed
        priority = TaskPriority(name: item.priority)
        billKind = BillKind(rawValue: item.billKind) ?? .other
        expiryKind = ExpiryKind(rawValue: item.expiryKind) ?? .other
        uncertain = Set(item.uncertainFields.filter { CaptureSchema.uncertainFieldNames.contains($0) })
        if amountIsApproximate { uncertain.insert("amount") }

        let categoryKind: CategoryKind = kind == .income || kind == .receivable ? .income : .expense
        let sameKind = categories.filter { $0.kind == categoryKind }
        category = DraftParsing.bestMatch(item.category, in: sameKind, name: \.name)
        // A catch-all the model reached for (「买瓷砖」 → 购物) gives way when the words say more (瓷砖 → 居住).
        if let chosen = category?.seedKey, ["shopping", "other-expense", "other-income"].contains(chosen),
           let guessed = LedgerCSV.guessedSeedKey(for: [item.title, item.note, item.quote].joined(separator: " "), kind: categoryKind),
           guessed != chosen, let better = sameKind.first(where: { $0.seedKey == guessed }) {
            category = better
        }
        // A category the person doesn't have (「装修」), or none: guess a built-in one from what it
        // was for, else file it under 其他 and flag it so the person looks.
        // Card repayments are transfers between the person's own accounts: no category.
        let wantsCategory = [.expense, .income, .receivable, .payable].contains(kind) || (kind == .bill && billKind != .creditCard)
        if category == nil, wantsCategory {
            let words = [item.category, item.title, item.note, item.quote].joined(separator: " ")
            category = LedgerCSV.guessedSeedKey(for: words, kind: categoryKind).flatMap { key in sameKind.first { $0.seedKey == key } }
            if category == nil {
                let otherKey = categoryKind == .income ? "other-income" : "other-expense"
                category = sameKind.first { $0.seedKey == otherKey }
                if category != nil { uncertain.insert("category") }
            }
        }
        let usable = accounts.filter { !$0.isArchived }
        account = DraftParsing.bestMatch(item.account, in: usable, name: \.name)
        toAccount = DraftParsing.bestMatch(item.toAccount, in: usable, name: \.name)

        hasTime = !item.time.isEmpty
        date = DraftParsing.date(item.date, time: item.time)
        dateIsApproximate = item.dateIsApproximate
        if dateIsApproximate { uncertain.insert("date") }
        switch kind {
        case .expense, .income, .transfer:
            if date == nil { date = now; hasTime = true }
        case .bill, .expiry:
            if date == nil { uncertain.insert("date") }
            if let day = date { date = calendar.startOfDay(for: day) }
            hasTime = false
        case .receivable, .payable:
            // When it's expected, only if someone said.
            if let day = date { date = calendar.startOfDay(for: day) }
            hasTime = false
        case .task, .note:
            break
        }

        recurrence = Self.recurrence(from: item, anchor: date)
        let days = item.reminderDaysBefore.filter { $0 >= 0 }
        switch kind {
        case .bill:
            reminderRules = (days.isEmpty ? [3, 0] : days).map { ReminderRule(daysBefore: $0) }
            if billKind == .creditCard {
                toAccount = toAccount ?? usable.first { $0.kind == .creditCard }
            }
        case .expiry:
            reminderRules = days.isEmpty ? expiryKind.defaultReminderRules : days.map { ReminderRule(daysBefore: $0) }
        default:
            reminderRules = []
        }
        reminderRules = Array(Set(reminderRules)).sorted { $0.daysBefore > $1.daysBefore }
    }

    private static func recurrence(from item: ParsedItem, anchor: Date?) -> Recurrence? {
        guard let frequency = Recurrence.Frequency(rawValue: item.repeatFrequency) else { return nil }
        var rule = Recurrence(frequency: frequency, interval: max(1, item.repeatInterval))
        if frequency == .weekly {
            rule.weekdays = item.repeatWeekdays.filter { (1...7).contains($0) }
        }
        if frequency == .monthly, item.repeatMonthDay != 0 {
            rule.monthDay = item.repeatMonthDay
        }
        return anchor.map { rule.normalized(anchor: $0) } ?? rule
    }

    /// Writes the draft as the matching model object and returns it. A note returns the
    /// entry it added, so tasks from the same capture can link to the sentence they came from.
    @discardableResult
    func save(in context: ModelContext, baseCurrency: String, linking entries: [NoteEntry] = [], now: Date = .now) -> SavedRecord? {
        let calendar = Calendar.current
        let name = title.trimmed
        switch kind {
        case .note:
            if let entry = appendsToEntry {
                let addition = note.trimmed
                entry.text = entry.text.trimmed.isEmpty ? addition : entry.text.trimmed + "\n\n" + addition
                entry.editedAt = now
                if isKeyPoint { entry.isKeyPoint = true }
                entry.note?.updatedAt = now
                return .noteEntry(entry)
            }
            let target: Note
            if updatesExisting, let existingNote {
                target = existingNote
            } else {
                target = Note(title: name)
                context.insert(target)
            }
            let entry = target.append(note.trimmed, date: now, source: .ai, in: context)
            entry.isKeyPoint = isKeyPoint
            return .noteEntry(entry)

        case .task:
            if updatesExisting, let existingTask {
                // Already on the list: tie it to the sentence if it isn't yet, don't add a second one.
                if existingTask.sourceEntry == nil, !quote.isEmpty,
                   let entry = entries.first(where: { $0.text.contains(quote) }) {
                    existingTask.sourceEntry = entry
                    existingTask.sourceQuote = quote
                }
                return .task(existingTask)
            }
            let task = TaskItem(title: name, dueDate: date.map { hasTime ? $0 : calendar.startOfDay(for: $0) },
                                hasDueTime: date != nil && hasTime, priority: priority, listName: listName)
            task.notes = note
            if let date { task.recurrence = recurrence?.normalized(anchor: date) }
            context.insert(task)
            if !quote.isEmpty, let entry = entries.first(where: { $0.text.contains(quote) }) {
                task.sourceEntry = entry
                task.sourceQuote = quote
            }
            return .task(task)

        case .expense, .income, .transfer:
            guard let amount else { return nil }
            let entryKind: EntryKind = kind == .expense ? .expense : kind == .income ? .income : .transfer
            let entry = LedgerEntry(kind: entryKind, amount: amount, currencyCode: currencyCode, date: date ?? now, note: name, source: .ai)
            context.insert(entry)
            entry.applyCurrentRate()
            entry.category = entryKind == .transfer ? nil : category
            entry.account = account
            entry.toAccount = entryKind == .transfer ? toAccount : nil
            return .ledger(entry)

        case .bill:
            guard let amount, let date else { return nil }
            let due = calendar.startOfDay(for: date)
            if updatesExisting, let bill = existingBill {
                bill.amount = amount
                bill.isAmountEstimated = amountIsApproximate
                bill.nextDueDate = due
                if let recurrence { bill.recurrence = recurrence.normalized(anchor: due) }
                if !note.isEmpty { bill.note = note }
                return .bill(bill)
            }
            let bill = Bill(name: name, kind: billKind, amount: amount, currencyCode: currencyCode,
                            nextDueDate: due, recurrence: recurrence?.normalized(anchor: due))
            bill.isAmountEstimated = amountIsApproximate
            bill.reminderRules = reminderRules
            bill.note = note
            context.insert(bill)
            bill.account = account
            if billKind == .creditCard {
                bill.creditAccount = toAccount
            } else {
                bill.category = category
            }
            return .bill(bill)

        case .receivable, .payable:
            guard let amount, let direction = kind.outstandingDirection else { return nil }
            let item = Outstanding(direction: direction, title: name, counterparty: counterparty.trimmed, amount: amount,
                                   currencyCode: currencyCode, dueDate: date.map { calendar.startOfDay(for: $0) })
            item.note = note
            context.insert(item)
            item.category = category
            item.account = account
            return .outstanding(item)

        case .expiry:
            guard let date else { return nil }
            let day = dateIsApproximate ? date.startOfMonth(calendar: calendar) : calendar.startOfDay(for: date)
            if updatesExisting, let existing = existingExpiry {
                existing.expiryDate = day
                existing.isDayUncertain = dateIsApproximate
                if !note.isEmpty { existing.note = note }
                return .expiry(existing)
            }
            let item = ExpiryItem(name: name, kind: expiryKind, expiryDate: day, isDayUncertain: dateIsApproximate)
            item.reminderRules = reminderRules
            item.note = note
            context.insert(item)
            return .expiry(item)
        }
    }

    /// The input with filler phrases struck through, for the "你说的" card.
    static func highlighted(_ text: String, fillers: [String]) -> AttributedString {
        var attributed = AttributedString(text)
        for phrase in Set(fillers.map(\.trimmed)) where !phrase.isEmpty {
            var searchStart = attributed.startIndex
            while searchStart < attributed.endIndex,
                  let range = attributed[searchStart...].range(of: phrase) {
                attributed[range].strikethroughStyle = .single
                attributed[range].foregroundColor = .secondary
                searchStart = range.upperBound
            }
        }
        return attributed
    }
}

private extension TaskPriority {
    init(name: String) {
        switch name {
        case "high": self = .high
        case "medium": self = .medium
        case "low": self = .low
        default: self = .none
        }
    }
}
