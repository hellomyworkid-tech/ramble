import Foundation
import SwiftData

@Model
final class Bill {
    var name: String = ""
    var kindRaw: String = BillKind.other.rawValue
    var amount: Decimal = 0
    var isAmountEstimated: Bool = false
    var currencyCode: String = "CNY"
    var nextDueDate: Date = Date.now
    var recurrenceData: Data?
    var reminderRulesData: Data?
    /// When paid, record an expense entry automatically.
    var autoRecord: Bool = true
    /// False once a one-off bill is paid.
    var isActive: Bool = true
    var note: String = ""
    var lastPaidAt: Date?
    var createdAt: Date = Date.now

    /// Pays from this account.
    var account: Account?
    /// Credit-card bills only: the card being repaid.
    var creditAccount: Account?
    var category: LedgerCategory?
    @Relationship(deleteRule: .nullify, inverse: \LedgerEntry.bill)
    var payments: [LedgerEntry]? = []

    init(name: String, kind: BillKind, amount: Decimal, currencyCode: String = "CNY", nextDueDate: Date, recurrence: Recurrence? = nil) {
        self.name = name
        self.kindRaw = kind.rawValue
        self.amount = amount
        self.currencyCode = currencyCode
        self.nextDueDate = nextDueDate
        self.recurrenceData = JSONStore.encode(recurrence)
        self.reminderRulesData = JSONStore.encode([ReminderRule(daysBefore: 3), ReminderRule(daysBefore: 0)])
        self.createdAt = .now
    }

    var kind: BillKind {
        get { BillKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    var recurrence: Recurrence? {
        get { JSONStore.decode(Recurrence.self, from: recurrenceData) }
        set { recurrenceData = JSONStore.encode(newValue) }
    }

    var reminderRules: [ReminderRule] {
        get { JSONStore.decode([ReminderRule].self, from: reminderRulesData) ?? [] }
        set { reminderRulesData = JSONStore.encode(newValue) }
    }

    /// Repaying a card moves money between your own accounts. The purchases were
    /// already recorded as spending, so counting the repayment again would double it.
    var recordsAsTransfer: Bool { kind == .creditCard }

    /// Records the payment (an expense, or a transfer for card repayments) and
    /// rolls the bill to its next period.
    @discardableResult
    func markPaid(amount paid: Decimal, on date: Date, from paymentAccount: Account?, recordEntry: Bool, in context: ModelContext) -> LedgerEntry? {
        var entry: LedgerEntry?
        if recordEntry {
            let newEntry = LedgerEntry(kind: recordsAsTransfer ? .transfer : .expense, amount: paid, currencyCode: currencyCode,
                                       date: date, note: name, source: .bill)
            context.insert(newEntry)
            newEntry.applyCurrentRate()
            newEntry.account = paymentAccount ?? account
            if recordsAsTransfer {
                newEntry.toAccount = creditAccount
            } else {
                newEntry.category = category
            }
            newEntry.bill = self
            entry = newEntry
        }
        lastPaidAt = date
        if let recurrence, let next = recurrence.nextOccurrence(after: nextDueDate) {
            nextDueDate = next
        } else {
            isActive = false
        }
        return entry
    }
}

@Model
final class ExpiryItem {
    var name: String = ""
    var kindRaw: String = ExpiryKind.document.rawValue
    var expiryDate: Date = Date.now
    /// Only the month is known ("护照明年三月到期").
    var isDayUncertain: Bool = false
    var reminderRulesData: Data?
    /// Typical validity after renewal, used by "已续期". 0 = unknown.
    var renewalMonths: Int = 0
    var note: String = ""
    var isArchived: Bool = false
    var createdAt: Date = Date.now
    @Relationship(deleteRule: .cascade, inverse: \Attachment.expiry)
    var attachments: [Attachment]? = []

    init(name: String, kind: ExpiryKind, expiryDate: Date, isDayUncertain: Bool = false) {
        self.name = name
        self.kindRaw = kind.rawValue
        self.expiryDate = expiryDate
        self.isDayUncertain = isDayUncertain
        self.reminderRulesData = JSONStore.encode(kind.defaultReminderRules)
        self.createdAt = .now
    }

    var kind: ExpiryKind {
        get { ExpiryKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    var reminderRules: [ReminderRule] {
        get { JSONStore.decode([ReminderRule].self, from: reminderRulesData) ?? [] }
        set { reminderRulesData = JSONStore.encode(newValue) }
    }

    var expiryText: String {
        isDayUncertain
            ? expiryDate.formatted(.dateTime.year().month(.wide))
            : expiryDate.formatted(.dateTime.year().month().day())
    }

    func renew(calendar: Calendar = .current) {
        guard renewalMonths > 0,
              let next = calendar.date(byAdding: .month, value: renewalMonths, to: expiryDate)
        else { return }
        expiryDate = next
    }
}
