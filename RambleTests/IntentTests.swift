import Foundation
import SwiftData
import Testing
@testable import Ramble

@MainActor
struct LedgerSummaryTests {
    private let container = AppSchema.makeContainer(inMemory: true)
    private let calendar = Calendar.current

    private func date(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    @Test func periodsCoverTheRightDays() {
        let now = date(10, 13)
        #expect(LedgerSummary.interval(.today, now: now).contains(date(10, 13, hour: 23)))
        #expect(!LedgerSummary.interval(.today, now: now).contains(date(10, 14, hour: 1)))
        let lastMonth = LedgerSummary.interval(.lastMonth, now: now)
        #expect(lastMonth.start == date(9, 1, hour: 0))
        #expect(lastMonth.end == date(10, 1, hour: 0))
        #expect(LedgerSummary.interval(.thisYear, now: now).start == date(1, 1, hour: 0))
    }

    @Test func expensesCountSubcategoriesAndSkipIncome() throws {
        let context = container.mainContext
        let food = LedgerCategory(name: "餐饮", kind: .expense, symbol: "fork.knife", colorHex: "#FF0000")
        let coffee = LedgerCategory(name: "咖啡", kind: .expense, symbol: "cup.and.saucer", colorHex: "#00FF00")
        coffee.parent = food
        let transport = LedgerCategory(name: "交通", kind: .expense, symbol: "car", colorHex: "#0000FF")
        [food, coffee, transport].forEach(context.insert)

        func add(_ kind: EntryKind, _ amount: Decimal, _ category: LedgerCategory?, on day: Date) {
            let entry = LedgerEntry(kind: kind, amount: amount, currencyCode: "CNY", date: day)
            entry.category = category
            context.insert(entry)
        }
        add(.expense, 35, food, on: date(10, 13))
        add(.expense, 18, coffee, on: date(10, 12))
        add(.expense, 40, transport, on: date(10, 2))
        add(.expense, 999, food, on: date(9, 30))
        add(.income, 5000, nil, on: date(10, 10))
        let budget = Budget(amount: 200)
        budget.category = food
        context.insert(budget)
        try context.save()

        let october = LedgerSummary.interval(.thisMonth, now: date(10, 13))
        #expect(LedgerSummary.expenses(in: october, context: context) == 93)
        #expect(LedgerSummary.expenses(in: october, categoryName: "餐饮", context: context) == 53)
        #expect(LedgerSummary.expenses(in: october, categoryName: "咖啡", context: context) == 18)
        #expect(LedgerSummary.monthlyBudget(categoryName: "餐饮", context: context) == 200)
        #expect(LedgerSummary.monthlyBudget(context: context) == nil)
    }
}

@MainActor
struct CaptureIntentTests {
    @Test func saidTextOpensTheSheetToTidyIt() async throws {
        let router = AppRouter.shared
        defer { router.pendingCapture = nil }

        let intent = CaptureIntent()
        intent.text = "  中午吃饭三十五 "
        _ = try await intent.perform()
        #expect(router.pendingCapture == .text("中午吃饭三十五"))

        intent.text = nil
        _ = try await intent.perform()
        #expect(router.pendingCapture == .voice)
    }

    @Test func linksOpenTabsAndCaptures() {
        let router = AppRouter.shared
        defer {
            router.pendingCapture = nil
            router.tab = .today
        }
        #expect(router.open(URL(string: "ramble://ledger")!))
        #expect(router.tab == .ledger)
        #expect(router.open(URL(string: "ramble://capture?text=%E6%89%93%E8%BD%A6%E4%BA%8C%E5%8D%81")!))
        #expect(router.pendingCapture == .text("打车二十"))
        #expect(router.open(URL(string: "ramble://capture")!))
        #expect(router.pendingCapture == .voice)
        #expect(!router.open(URL(string: "https://example.com")!))
        #expect(!router.open(URL(string: "ramble://nowhere")!))
    }
}

@MainActor
struct WidgetBridgeTests {
    private let container = AppSchema.makeContainer(inMemory: true)

    private func date(_ day: Int, _ hour: Int = 12) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    @Test func summaryHoldsTodayTasksSpendingAndWhatsDue() throws {
        let context = container.mainContext
        let now = date(13, 9)
        let overdue = TaskItem(title: "交房租", dueDate: date(12), priority: .high)
        let today = TaskItem(title: "交季度报告", dueDate: date(13, 18), hasDueTime: true)
        let tomorrow = TaskItem(title: "取快递", dueDate: date(14))
        let later = TaskItem(title: "体检", dueDate: date(20))
        let done = TaskItem(title: "已完成", dueDate: date(13))
        done.isCompleted = true
        [overdue, today, tomorrow, later, done].forEach(context.insert)
        context.insert(LedgerEntry(kind: .expense, amount: 35, currencyCode: "CNY", date: date(13, 8)))
        context.insert(LedgerEntry(kind: .expense, amount: 100, currencyCode: "CNY", date: date(2)))
        context.insert(LedgerEntry(kind: .income, amount: 9000, currencyCode: "CNY", date: date(10)))
        context.insert(LedgerEntry(kind: .expense, amount: 999, currencyCode: "CNY", date: date(1, 0).addingTimeInterval(-3600)))
        context.insert(Budget(amount: 2000))
        context.insert(Bill(name: "信用卡还款", kind: .creditCard, amount: 2180, nextDueDate: date(15)))
        context.insert(ExpiryItem(name: "护照", kind: .document, expiryDate: date(30)))
        try context.save()

        let snapshot = WidgetBridge.makeSnapshot(context: context, now: now)
        #expect(snapshot.tasks.map(\.title) == ["交房租", "交季度报告", "取快递"])
        #expect(snapshot.tasks(dueBy: now, excluding: []).map(\.title) == ["交房租", "交季度报告"])
        #expect(snapshot.tasks(dueBy: date(14, 0), excluding: [snapshot.tasks[0].id]).map(\.title) == ["交季度报告", "取快递"])
        #expect(snapshot.monthExpense == 135)
        #expect(snapshot.todayExpense == 35)
        #expect(snapshot.monthIncome == 9000)
        #expect(snapshot.monthBudget == 2000)
        #expect(snapshot.upcoming.map(\.name) == ["信用卡还款", "护照"])

        // Round trip through JSON, as the widget reads it.
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
        var later2 = snapshot
        later2.generatedAt = now.addingTimeInterval(60)
        #expect(snapshot.sameContent(as: later2))
    }

    @Test func widgetCompletionsAreRecordedByTheApp() throws {
        let context = container.mainContext
        let once = TaskItem(title: "交报告", dueDate: date(13))
        let weekly = TaskItem(title: "倒垃圾", dueDate: date(13))
        weekly.recurrence = .init(frequency: .weekly)
        context.insert(once)
        context.insert(weekly)
        try context.save()
        let ids = [once, weekly].map { ModelRef.encode($0.persistentModelID) }
        defer { WidgetStore.clearPendingCompletions(ids) }

        ids.forEach(WidgetStore.addPendingCompletion)
        WidgetStore.addPendingCompletion(ids[0])
        #expect(WidgetStore.pendingCompletions().filter(ids.contains).count == 2)

        #expect(WidgetBridge.applyPendingCompletions(context: context, now: date(13, 10)) == 2)
        #expect(once.isCompleted)
        // A repeating task moves on to its next date instead of closing.
        #expect(!weekly.isCompleted && weekly.dueDate == date(20))
        #expect(WidgetStore.pendingCompletions().filter(ids.contains).isEmpty)
    }
}
