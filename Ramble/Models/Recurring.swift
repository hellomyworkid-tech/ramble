import Foundation
import SwiftData

/// Income or spending that comes round by itself: 工资, 房租, 订阅. On its day it's recorded as a
/// ledger entry, or, when the amount varies, waits on the Today page for a yes (`asksFirst`).
@Model
final class RecurringEntry {
    var kindRaw: String = EntryKind.income.rawValue
    var name: String = ""
    var amount: Decimal = 0
    var currencyCode: String = "CNY"
    /// The next occurrence not yet recorded or skipped.
    var nextDate: Date = Date.now
    var recurrenceData: Data?
    var asksFirst: Bool = false
    /// False once it has run out: one that doesn't repeat, or past its end date.
    var isActive: Bool = true
    var createdAt: Date = Date.now

    var account: Account?
    var category: LedgerCategory?
    /// What it has recorded. They stay when the rule is deleted.
    @Relationship(deleteRule: .nullify, inverse: \LedgerEntry.recurring)
    var entries: [LedgerEntry]? = []

    init(kind: EntryKind, name: String, amount: Decimal, currencyCode: String = "CNY", nextDate: Date, recurrence: Recurrence?) {
        self.kindRaw = kind.rawValue
        self.name = name
        self.amount = amount
        self.currencyCode = currencyCode
        self.nextDate = Self.occurrence(on: nextDate)
        self.recurrenceData = JSONStore.encode(recurrence)
        self.createdAt = .now
    }

    var kind: EntryKind {
        get { EntryKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }

    var recurrence: Recurrence? {
        get { JSONStore.decode(Recurrence.self, from: recurrenceData) }
        set { recurrenceData = JSONStore.encode(newValue) }
    }

    /// Midday, well clear of the day's edges if the person travels across time zones.
    static func occurrence(on day: Date, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }

    /// Its next occurrence has come round.
    func isDue(now: Date = .now, calendar: Calendar = .current) -> Bool {
        isActive && calendar.startOfDay(for: nextDate) <= calendar.startOfDay(for: now)
    }

    /// Records the next occurrence and moves on to the one after. Nil if it's already recorded:
    /// another device may have got there first and its copy arrived before this rule's new date.
    @discardableResult
    func record(amount paid: Decimal? = nil, account chosen: Account? = nil, in context: ModelContext) -> LedgerEntry? {
        let occurrence = nextDate
        defer { moveOn() }
        let alreadyThere = (entries ?? []).contains { entry in
            entry.occurrenceDate.map { Calendar.current.isDate($0, inSameDayAs: occurrence) } ?? false
        }
        guard !alreadyThere else { return nil }
        let entry = LedgerEntry(kind: kind, amount: paid ?? amount, currencyCode: currencyCode, date: occurrence, note: name, source: .recurring)
        context.insert(entry)
        entry.applyCurrentRate()
        entry.account = chosen ?? account
        entry.category = category
        entry.recurring = self
        entry.occurrenceDate = occurrence
        return entry
    }

    /// Passes over the next occurrence without recording it.
    func skip() { moveOn() }

    private func moveOn() {
        if let next = recurrence?.nextOccurrence(after: nextDate) {
            nextDate = next
        } else {
            isActive = false
        }
    }
}

enum RecurringEntries {
    /// Records what has come round since the app last looked, each on its own day, except what
    /// asks first. Returns how many entries that made.
    @discardableResult
    static func recordDue(in context: ModelContext, now: Date = .now) -> Int {
        let rules = (try? context.fetch(FetchDescriptor<RecurringEntry>(predicate: #Predicate { $0.isActive && !$0.asksFirst }))) ?? []
        var recorded = 0, moved = false
        for rule in rules where !PendingDeletion.shared.hides(rule) {
            // A daily rule left for years shouldn't hold the app up; the rest follow next time.
            for _ in 0..<400 where rule.isDue(now: now) {
                if rule.record(in: context) != nil { recorded += 1 }
                moved = true
            }
        }
        if moved { try? context.save() }
        return recorded
    }
}
