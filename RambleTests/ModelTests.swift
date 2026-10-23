import Foundation
import SwiftData
import Testing
@testable import Ramble

struct ModelTests {
    private let container = AppSchema.makeContainer(inMemory: true)

    @Test func payingRecurringBillRecordsExpenseAndRollsForward() throws {
        let context = container.mainContext
        let calendar = Calendar.current
        let due = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let bill = Bill(name: "房租", kind: .rent, amount: 3500, nextDueDate: due, recurrence: .monthly(day: 1))
        context.insert(bill)

        let entry = bill.markPaid(amount: 3500, on: due, from: nil, recordEntry: true, in: context)

        #expect(entry?.amount == 3500)
        #expect(entry?.kind == .expense)
        #expect(entry?.bill == bill)
        #expect(bill.nextDueDate == calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        #expect(bill.isActive)
    }

    /// A budget left without its category would read as the overall budget; it goes with the category.
    @Test func deletingACategoryTakesItsBudgetAlongAndLeavesEntries() throws {
        let context = container.mainContext
        let food = LedgerCategory(name: "餐饮", kind: .expense, symbol: "fork.knife", colorHex: "#D9480F")
        context.insert(food)
        let budget = Budget(amount: 800)
        context.insert(budget)
        budget.category = food
        let overall = Budget(amount: 6000)
        context.insert(overall)
        let lunch = LedgerEntry(kind: .expense, amount: 35, currencyCode: "CNY", note: "午餐")
        context.insert(lunch)
        lunch.category = food
        try context.save()

        context.delete(food)
        try context.save()
        let budgets = try context.fetch(FetchDescriptor<Budget>())
        #expect(budgets.map(\.amount) == [6000])
        #expect(try context.fetchCount(FetchDescriptor<LedgerEntry>()) == 1)
        #expect(lunch.category == nil)
    }

    /// Purchases on the card were already spending; the repayment must not count again.
    @Test func creditCardRepaymentIsATransferToTheCard() {
        let context = container.mainContext
        let debit = Account(name: "储蓄卡", kind: .debitCard, initialBalance: 5000)
        let card = Account(name: "信用卡", kind: .creditCard)
        context.insert(debit)
        context.insert(card)
        let shoes = LedgerEntry(kind: .expense, amount: 268, currencyCode: "CNY")
        context.insert(shoes)
        shoes.account = card

        let bill = Bill(name: "信用卡还款", kind: .creditCard, amount: 268, nextDueDate: .now, recurrence: .monthly(day: 15))
        context.insert(bill)
        bill.account = debit
        bill.creditAccount = card

        let entry = bill.markPaid(amount: 268, on: .now, from: nil, recordEntry: true, in: context)

        #expect(entry?.kind == .transfer)
        #expect(entry?.category == nil)
        #expect(card.balance == 0)
        #expect(debit.balance == 4732)
    }

    @Test func payingOneOffBillEndsIt() {
        let context = container.mainContext
        let bill = Bill(name: "保险", kind: .insurance, amount: 3200, nextDueDate: .now)
        context.insert(bill)

        let entry = bill.markPaid(amount: 3200, on: .now, from: nil, recordEntry: false, in: context)

        #expect(entry == nil)
        #expect(!bill.isActive)
    }

    @Test func completingRepeatingTaskRollsItForward() {
        let context = container.mainContext
        let calendar = Calendar.current
        let due = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 18))!
        let task = TaskItem(title: "健身", dueDate: due, hasDueTime: true)
        task.recurrence = Recurrence(frequency: .daily, interval: 2)
        context.insert(task)

        task.toggleCompletion()

        #expect(!task.isCompleted)
        #expect(task.dueDate == calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 18)))
    }

    @Test func accountBalanceFollowsEntriesAndTransfers() {
        let context = container.mainContext
        let card = Account(name: "储蓄卡", kind: .debitCard, initialBalance: 1000)
        let cash = Account(name: "现金", kind: .cash)
        context.insert(card)
        context.insert(cash)

        let lunch = LedgerEntry(kind: .expense, amount: 35, currencyCode: "CNY")
        let salary = LedgerEntry(kind: .income, amount: 500, currencyCode: "CNY")
        let withdraw = LedgerEntry(kind: .transfer, amount: 200, currencyCode: "CNY")
        [lunch, salary, withdraw].forEach(context.insert)
        lunch.account = card
        salary.account = card
        withdraw.account = card
        withdraw.toAccount = cash

        #expect(card.balance == 1265)
        #expect(cash.balance == 200)
    }

    @Test func seedingRunsOnce() throws {
        let context = container.mainContext
        SeedData.seedDefaultsIfNeeded(context)
        let first = try context.fetchCount(FetchDescriptor<LedgerCategory>())
        SeedData.seedDefaultsIfNeeded(context)
        let second = try context.fetchCount(FetchDescriptor<LedgerCategory>())
        #expect(first > 0)
        #expect(first == second)
    }
}
