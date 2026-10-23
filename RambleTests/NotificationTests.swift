import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import Ramble

struct ReminderPlannerTests {
    private let calendar = Calendar.current

    private func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func dateOnlyTasksFireAtNine() {
        let now = date(10, 11, 8)
        let reminders = ReminderPlanner.taskReminders(id: "t", title: "买菜", due: date(10, 12), hasTime: false,
                                                      minutesBefore: [0, 1440], now: now)
        #expect(reminders.map(\.fireDate) == [date(10, 12, 9), date(10, 11, 9)])
        #expect(reminders.map(\.body) == ["今天要做", "明天要做"])
    }

    @Test func timedTasksFireBeforeTheDueTime() {
        let reminders = ReminderPlanner.taskReminders(id: "t", title: "交季度报告", due: date(10, 11, 18), hasTime: true,
                                                      minutesBefore: [15], now: date(10, 11, 8))
        #expect(reminders.first?.fireDate == date(10, 11, 17, 45))
        #expect(reminders.first?.body.contains("15 分钟后到期") == true)
        #expect(reminders.first?.category == ReminderPlanner.Category.task)
    }

    @Test func billRemindersCountDownAndFlagEstimates() {
        let rules = [ReminderRule(daysBefore: 3), ReminderRule(daysBefore: 0)]
        let reminders = ReminderPlanner.billReminders(id: "b", name: "信用卡还款", due: date(10, 15), amountText: "¥2,000.00",
                                                      isEstimated: true, rules: rules, now: date(10, 11, 8))
        #expect(reminders.map(\.fireDate) == [date(10, 12, 9), date(10, 15, 9)])
        #expect(reminders.map(\.title) == ["信用卡还款 · 3 天后到期", "信用卡还款 · 今天到期"])
        #expect(reminders.allSatisfy { $0.category == ReminderPlanner.Category.billEstimated })
    }

    @Test func pastRemindersAreDropped() {
        let rules = [ReminderRule(daysBefore: 3), ReminderRule(daysBefore: 0)]
        let reminders = ReminderPlanner.billReminders(id: "b", name: "房租", due: date(10, 15), amountText: "¥3,500.00",
                                                      isEstimated: false, rules: rules, now: date(10, 13, 8))
        #expect(reminders.count == 1)
    }

    @Test func expiryRemindersSuggestRenewingEarly() {
        let rules = [ReminderRule(daysBefore: 90), ReminderRule(daysBefore: 7)]
        let reminders = ReminderPlanner.expiryReminders(id: "e", name: "护照", expiry: date(12, 31), expiryText: "2026年12月31日",
                                                        renewable: true, rules: rules, now: date(9, 1))
        #expect(reminders.first?.title == "护照 · 还有 90 天到期")
        #expect(reminders.first?.body.contains("续期") == true)
        #expect(reminders.last?.body.contains("续期") == false)
        #expect(reminders.first?.category == ReminderPlanner.Category.expiryRenewable)
    }

    @Test func selectionKeepsTheSoonestAndNudgesWhenFull() {
        let now = date(10, 1)
        let reminders = (1...70).reversed().map { offset in
            PlannedReminder(target: .task, targetID: "\(offset)", fireDate: now.addingTimeInterval(Double(offset) * 3600),
                            title: "\(offset)", body: "", category: ReminderPlanner.Category.task, threadID: "")
        }
        let selected = ReminderPlanner.select(reminders, now: now)
        #expect(selected.count == ReminderPlanner.limit)
        #expect(selected.first?.title == "1")
        #expect(selected.dropLast().last?.title == "63")
        #expect(selected.last?.target == .openApp)
        #expect(selected.last?.fireDate == now.addingTimeInterval(63 * 3600 + 60))
    }

    @Test func selectionUnderTheLimitIsJustSorted() {
        let now = date(10, 1)
        let late = PlannedReminder(target: .bill, targetID: "a", fireDate: now.addingTimeInterval(7200), title: "late", body: "", category: "", threadID: "")
        let early = PlannedReminder(target: .bill, targetID: "b", fireDate: now.addingTimeInterval(3600), title: "early", body: "", category: "", threadID: "")
        let past = PlannedReminder(target: .bill, targetID: "c", fireDate: now.addingTimeInterval(-60), title: "past", body: "", category: "", threadID: "")
        #expect(ReminderPlanner.select([late, past, early], now: now).map(\.title) == ["early", "late"])
    }

    @Test func snoozesShrinkTheAvailableSlots() {
        let now = date(10, 1)
        let reminders = (1...10).map { offset in
            PlannedReminder(target: .task, targetID: "\(offset)", fireDate: now.addingTimeInterval(Double(offset) * 60),
                            title: "\(offset)", body: "", category: "", threadID: "")
        }
        let selected = ReminderPlanner.select(reminders, now: now, limit: 5)
        #expect(selected.count == 5)
        #expect(selected.last?.target == .openApp)
    }
}

struct NotificationActionTests {
    private let container = AppSchema.makeContainer(inMemory: true)

    @Test func modelReferencesSurviveARoundTripAndDeletion() throws {
        let context = container.mainContext
        let task = TaskItem(title: "健身")
        context.insert(task)
        try context.save()

        let reference = ModelRef.encode(task.persistentModelID)
        #expect(ModelRef.fetch(TaskItem.self, reference, in: context) === task)

        context.delete(task)
        try context.save()
        #expect(ModelRef.fetch(TaskItem.self, reference, in: context) == nil)
    }

    @Test func completeActionFinishesTheTask() throws {
        let context = container.mainContext
        let task = TaskItem(title: "交季度报告", dueDate: .now, hasDueTime: true)
        context.insert(task)
        try context.save()

        let changed = NotificationActions.apply(.complete, target: .task, id: ModelRef.encode(task.persistentModelID), in: context)
        #expect(changed)
        #expect(task.isCompleted)
    }

    @Test func markPaidActionRecordsAndRollsTheBill() throws {
        let context = container.mainContext
        let calendar = Calendar.current
        let due = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let bill = Bill(name: "房租", kind: .rent, amount: 3500, nextDueDate: due, recurrence: .monthly(day: 1))
        context.insert(bill)
        try context.save()
        let id = ModelRef.encode(bill.persistentModelID)

        #expect(NotificationActions.apply(.markPaid, target: .bill, id: id, in: context))
        #expect(bill.nextDueDate == calendar.date(from: DateComponents(year: 2026, month: 12, day: 1)))
        #expect(try context.fetchCount(FetchDescriptor<LedgerEntry>()) == 1)
    }

    @Test func renewActionNeedsAKnownValidity() throws {
        let context = container.mainContext
        let calendar = Calendar.current
        let expiry = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20))!
        let insurance = ExpiryItem(name: "车险", kind: .insurance, expiryDate: expiry)
        context.insert(insurance)
        try context.save()
        let id = ModelRef.encode(insurance.persistentModelID)

        #expect(!NotificationActions.apply(.renewed, target: .expiry, id: id, in: context))
        insurance.renewalMonths = 12
        #expect(NotificationActions.apply(.renewed, target: .expiry, id: id, in: context))
        #expect(insurance.expiryDate == calendar.date(from: DateComponents(year: 2027, month: 11, day: 20)))
    }

    @Test func tappingANotificationOpensItsRecord() async throws {
        let context = container.mainContext
        let bill = Bill(name: "房租", kind: .rent, amount: 3500, nextDueDate: .now)
        context.insert(bill)
        try context.save()
        let id = ModelRef.encode(bill.persistentModelID)
        let router = AppRouter.shared
        router.tab = .today
        router.focus = nil

        let tap = NotificationPayload(action: UNNotificationDefaultActionIdentifier, target: "bill", id: id,
                                      title: "", body: "", category: ReminderPlanner.Category.bill, threadID: "")
        await NotificationHandler.handle(tap)
        #expect(router.tab == .reminders)
        #expect(router.focus == .bill(bill.persistentModelID, pay: false))

        let pay = NotificationPayload(action: NotificationAction.payInApp.rawValue, target: "bill", id: id,
                                      title: "", body: "", category: ReminderPlanner.Category.billEstimated, threadID: "")
        await NotificationHandler.handle(pay)
        #expect(router.focus == .bill(bill.persistentModelID, pay: true))
        router.focus = nil
    }

    @Test func schedulerPlansEveryKindOfReminder() throws {
        let context = container.mainContext
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 8))!
        context.insert(TaskItem(title: "预约牙医", dueDate: calendar.date(byAdding: .day, value: 1, to: now), hasDueTime: true))
        context.insert(Bill(name: "房租", kind: .rent, amount: 3500, nextDueDate: calendar.date(byAdding: .day, value: 10, to: now)!))
        context.insert(ExpiryItem(name: "护照", kind: .document, expiryDate: calendar.date(byAdding: .day, value: 200, to: now)!))
        let done = TaskItem(title: "已完成", dueDate: calendar.date(byAdding: .day, value: 1, to: now))
        done.isCompleted = true
        context.insert(done)
        try context.save()

        let planned = NotificationScheduler().plan(in: context, now: now)
        #expect(planned.filter { $0.target == .task }.count == 1)
        #expect(planned.filter { $0.target == .bill }.count == 2)
        #expect(planned.filter { $0.target == .expiry }.count == 3)
    }
}
