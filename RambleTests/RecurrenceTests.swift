import Foundation
import Testing
@testable import Ramble

struct RecurrenceTests {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func dailyAddsInterval() {
        let rule = Recurrence(frequency: .daily, interval: 3)
        #expect(rule.nextOccurrence(after: date(2026, 10, 11), calendar: calendar) == date(2026, 10, 14))
    }

    @Test func workdaysSkipWeekend() {
        // 2026-10-16 is a Friday.
        let next = Recurrence.workdaysOnly.nextOccurrence(after: date(2026, 10, 16), calendar: calendar)
        #expect(next == date(2026, 10, 19))
    }

    @Test func biweeklyKeepsWeekday() {
        let next = Recurrence.biweekly.nextOccurrence(after: date(2026, 10, 11), calendar: calendar)
        #expect(next == date(2026, 10, 25))
    }

    @Test func monthlyOn31stClampsWithoutDrifting() {
        let rule = Recurrence.monthly(day: 31)
        let feb = rule.nextOccurrence(after: date(2027, 1, 31), calendar: calendar)
        #expect(feb == date(2027, 2, 28))
        let march = feb.flatMap { rule.nextOccurrence(after: $0, calendar: calendar) }
        #expect(march == date(2027, 3, 31))
    }

    @Test func lastDayOfMonthHandlesLeapYear() {
        let rule = Recurrence.monthly(day: Recurrence.lastDayOfMonth)
        #expect(rule.nextOccurrence(after: date(2028, 1, 31), calendar: calendar) == date(2028, 2, 29))
        #expect(rule.nextOccurrence(after: date(2028, 2, 29), calendar: calendar) == date(2028, 3, 31))
    }

    @Test func normalizedPinsMonthDayToAnchor() {
        let rule = Recurrence.monthly().normalized(anchor: date(2026, 10, 31), calendar: calendar)
        #expect(rule.monthDay == 31)
    }

    @Test func endDateStopsTheRule() {
        var rule = Recurrence.daily
        rule.endDate = date(2026, 10, 12, 0)
        #expect(rule.nextOccurrence(after: date(2026, 10, 11), calendar: calendar) == nil)
    }

    @Test func firstMonthlyPicksThisOrNextMonth() {
        #expect(Recurrence.firstMonthly(day: 15, onOrAfter: date(2026, 10, 11), calendar: calendar) == date(2026, 10, 15))
        #expect(Recurrence.firstMonthly(day: 1, onOrAfter: date(2026, 10, 11), calendar: calendar) == date(2026, 11, 1))
    }

    @Test func reminderSummaryListsEarlyDaysThenSameDay() {
        let rules = [ReminderRule(daysBefore: 7), ReminderRule(daysBefore: 0), ReminderRule(daysBefore: 90), ReminderRule(daysBefore: 30)]
        #expect(ReminderRule.summary(of: rules) == "提前 90 / 30 / 7 天 · 当天 9:00")
    }

    @Test func reminderFireDateIsDaysBeforeAtTime() {
        let rule = ReminderRule(daysBefore: 3, hour: 20, minute: 30)
        #expect(rule.fireDate(for: date(2026, 10, 15), calendar: calendar) == calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 20, minute: 30)))
    }
}
