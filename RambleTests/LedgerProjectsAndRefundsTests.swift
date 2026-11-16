import Foundation
import SwiftData
import Testing
@testable import Ramble

private func day(_ text: String, _ time: String = "12:00") -> Date {
    DraftParsing.date(text, time: time) ?? .now
}

private func item(_ type: String, _ title: String, amount: String = "") -> ParsedItem {
    var item = ParsedItem()
    item.type = type
    item.title = title
    item.amount = amount
    return item
}

@MainActor
struct RefundTests {
    private let container = AppSchema.inMemoryContainer()
    private var context: ModelContext { container.mainContext }

    private func expense(_ amount: Decimal, _ note: String = "运动鞋", on date: String = "2026-10-10", in account: Account? = nil) -> LedgerEntry {
        let entry = LedgerEntry(kind: .expense, amount: amount, currencyCode: "CNY", date: day(date), note: note)
        context.insert(entry)
        entry.account = account
        return entry
    }

    @Test func aRefundTakesTheSpendingDownWhereItHappened() {
        let shoes = expense(268)
        _ = expense(100, "午餐")
        shoes.recordRefund(68, on: day("2026-11-03"))

        #expect(shoes.netAmount == 200)
        #expect(shoes.baseAmount == 200)
        let october = LedgerSummary.expenses(in: DateInterval(start: day("2026-10-01", "00:00"), end: day("2026-11-01", "00:00")), context: context)
        #expect(october == 300)
        let november = LedgerSummary.expenses(in: DateInterval(start: day("2026-11-01", "00:00"), end: day("2026-12-01", "00:00")), context: context)
        #expect(november == 0)
    }

    @Test func aRefundFollowsTheEntrysOwnRate() {
        let entry = LedgerEntry(kind: .expense, amount: 100, currencyCode: "USD", date: day("2026-10-10"))
        context.insert(entry)
        entry.rateToBase = 7
        entry.recordRefund(40)
        #expect(entry.baseAmount == 420)
        #expect(entry.amount(in: "USD") == 60)
    }

    @Test func theMoneyGoesBackIntoTheAccount() {
        let card = Account(name: "招行", kind: .debitCard, currencyCode: "CNY", initialBalance: 1000)
        context.insert(card)
        let shoes = expense(268, in: card)
        #expect(card.balance == 732)
        shoes.recordRefund(268)
        #expect(card.balance == 1000)
    }

    @Test func aRefundNeverComesToMoreThanWasSpent() {
        let shoes = expense(268)
        shoes.recordRefund(100)
        shoes.recordRefund(500)
        #expect(shoes.refundedAmount == 268)
        #expect(shoes.netAmount == 0)
    }

    @Test func undoingPutsItBack() {
        let shoes = expense(268)
        shoes.recordRefund(100)
        shoes.undoRefund()
        #expect(shoes.netAmount == 268)
        #expect(shoes.refundedAt == nil)
    }

    @Test func onlySpendingCanBeRefunded() {
        let salary = LedgerEntry(kind: .income, amount: 12000, currencyCode: "CNY")
        context.insert(salary)
        salary.recordRefund(100)
        #expect(salary.refundedAmount == 0)
    }

    @Test func questionsCountWhatsLeftAfterTheRefund() {
        expense(268).recordRefund(68)
        let period = PeriodResolver.month(containing: day("2026-10-10"), now: day("2026-10-13"), label: "10月")
        let answer = QueryRunner.run(QueryPlan(subject: .expense, measure: .total, period: period), context: context, now: day("2026-10-13"))
        #expect(answer.headline.contains(Decimal(200).money("CNY")))
    }

    // MARK: Saying it

    @Test(arguments: ["运动鞋退款", "淘宝退钱了", "退货", "机票退票", "押金退回来了", "鞋退了", "Shoes refund"])
    func itsHeardAsARefund(_ words: String) {
        #expect(RefundCues.isRefund(words))
    }

    @Test(arguments: ["退税", "个税退税到账", "退休金", "工资", "退出会员"])
    func itsNotARefund(_ words: String) {
        #expect(!RefundCues.isRefund(words))
    }

    @Test func theSpendingIsFoundByWhatItWas() {
        let lunch = expense(35, "午餐")
        let shoes = expense(268)
        #expect(RefundCues.original(of: "运动鞋退款", amount: 100, among: [lunch, shoes]) === shoes)
    }

    @Test func amongTheSameThingTheSameAmountWins() {
        let newest = expense(99, "运动鞋", on: "2026-10-20")
        let older = expense(268, "运动鞋", on: "2026-10-01")
        #expect(RefundCues.original(of: "运动鞋退款", amount: 268, among: [newest, older]) === older)
        #expect(RefundCues.original(of: "运动鞋退款", amount: 1, among: [newest, older]) === newest)
    }

    @Test func withoutANameTheAmountDecides() {
        let lunch = expense(35, "午餐")
        let shoes = expense(268)
        #expect(RefundCues.original(of: "退款", amount: 268, among: [lunch, shoes]) === shoes)
    }

    @Test func itDoesntGuessWhenNothingSays() {
        let lunch = expense(35, "午餐")
        #expect(RefundCues.original(of: "退款", amount: 268, among: [lunch]) == nil)
        #expect(RefundCues.original(of: "退款", amount: nil, among: [lunch]) == nil)
    }

    @Test func spendingFullyRefundedIsNoLongerOffered() {
        let shoes = expense(268, on: DraftParsing.day(.now))
        let lunch = expense(35, "午餐", on: DraftParsing.day(.now))
        shoes.recordRefund(268)
        #expect(RefundCues.candidates(in: context).map(\.note) == [lunch.note])
    }

    @Test func aSpokenRefundGoesOnTheEntryInsteadOfMakingAnother() throws {
        let shoes = expense(268)
        var draft = CaptureDraft(item: item("income", "运动鞋退款", amount: "268"), categories: [], accounts: [], baseCurrency: "CNY")
        #expect(draft.kind == .refund)
        draft.linkExisting(bills: [], expiries: [], expenses: [shoes])
        #expect(draft.problem == nil)

        let saved = draft.save(in: context, baseCurrency: "CNY")
        if case .ledger(let entry) = saved { #expect(entry === shoes) } else { Issue.record("Didn't save onto the entry") }
        #expect(shoes.netAmount == 0)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<LedgerEntry>()) == 1)
    }

    @Test func aRefundWithNothingToGoOnAsksWhichOne() {
        var draft = CaptureDraft(item: item("income", "退款", amount: "50"), categories: [], accounts: [], baseCurrency: "CNY")
        draft.linkExisting(bills: [], expiries: [], expenses: [])
        #expect(draft.kind == .refund)
        #expect(draft.problem != nil)
    }

    @Test func aTaxRefundIsStillIncome() {
        let draft = CaptureDraft(item: item("income", "退税", amount: "500"), categories: [], accounts: [], baseCurrency: "CNY")
        #expect(draft.kind == .income)
    }
}

@MainActor
struct ProjectTests {
    private let container = AppSchema.inMemoryContainer()
    private var context: ModelContext { container.mainContext }

    @discardableResult
    private func add(_ kind: EntryKind, _ amount: Decimal, _ note: String, _ project: Project?, on date: String = "2026-10-10") -> LedgerEntry {
        let entry = LedgerEntry(kind: kind, amount: amount, currencyCode: "CNY", date: day(date), note: note)
        context.insert(entry)
        entry.project = project
        return entry
    }

    private func renovation() -> Project {
        let project = Project(name: "装修")
        context.insert(project)
        return project
    }

    @Test func itAddsUpSpendingAcrossMonthsLessRefunds() {
        let project = renovation()
        add(.expense, 3200, "瓷砖", project, on: "2026-09-02")
        add(.expense, 860, "灯具", project, on: "2026-10-10").recordRefund(60)
        add(.income, 500, "卖旧家具", project)
        add(.expense, 35, "午餐", nil)
        #expect(project.spent == 4000)
    }

    @Test func theLongestNameWins() {
        let short = Project(name: "装修")
        let long = Project(name: "厨房装修")
        #expect(Project.named(in: "厨房装修买瓷砖", among: [short, long]) === long)
        #expect(Project.named(in: "装修买瓷砖", among: [short, long]) === short)
        #expect(Project.named(in: "午餐", among: [short, long]) == nil)
    }

    @Test func deletingItKeepsTheEntriesAndNotes() throws {
        let project = renovation()
        let entry = add(.expense, 3200, "瓷砖", project)
        let note = Note(title: "装修记录")
        context.insert(note)
        note.project = project
        try context.save()

        context.delete(project)
        try context.save()
        #expect(entry.project == nil)
        #expect(note.project == nil)
        #expect(try context.fetchCount(FetchDescriptor<LedgerEntry>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Note>()) == 1)
    }

    @Test func aSpokenExpenseGoesToTheProjectItNames() {
        let project = renovation()
        var words = item("expense", "瓷砖", amount: "3200")
        // A category the person doesn't have: the model's way of saying what it was for.
        words.category = "装修"
        var draft = CaptureDraft(item: words, categories: [], accounts: [], baseCurrency: "CNY")
        draft.linkExisting(bills: [], expiries: [], projects: [project])
        #expect(draft.project === project)

        if case .ledger(let entry) = draft.save(in: context, baseCurrency: "CNY") {
            #expect(entry.project === project)
        } else {
            Issue.record("Didn't save an entry")
        }
    }

    @Test func anExpenseThatNamesNoProjectStaysOut() {
        let project = renovation()
        var draft = CaptureDraft(item: item("expense", "午餐", amount: "35"), categories: [], accounts: [], baseCurrency: "CNY")
        draft.linkExisting(bills: [], expiries: [], projects: [project])
        #expect(draft.project == nil)
    }

    // MARK: Asking

    private let now = day("2026-11-06")

    private func answer(_ question: String) throws -> AskAnswer {
        let plan = try #require(QuestionParser.parse(question, categories: [], now: now).plan)
        return QueryRunner.run(plan, context: context, now: now)
    }

    @Test(arguments: ["装修一共花了多少", "装修花了多少钱"])
    func askingCountsTheWholeProject(_ question: String) throws {
        let project = renovation()
        // Months apart, and neither note mentions it.
        add(.expense, 3200, "瓷砖", project, on: "2026-08-02")
        add(.expense, 860, "灯具", project, on: "2026-10-10")
        add(.expense, 35, "午餐", nil, on: "2026-10-10")

        let reply = try answer(question)
        #expect(reply.headline.contains(Decimal(4060).money("CNY")), "\(reply.headline)")
        #expect(reply.headline.contains("2"), "\(reply.headline)")
        #expect(!reply.details.contains { $0.contains("日均") })
    }

    @Test func aWordThatIsntAProjectStillMeansThisMonth() throws {
        add(.expense, 18, "咖啡", nil, on: "2026-11-02")
        add(.expense, 30, "咖啡", nil, on: "2026-10-02")
        let reply = try answer("咖啡花了多少钱")
        #expect(reply.headline.contains(Decimal(18).money("CNY")), "\(reply.headline)")
    }

    // MARK: Backups

    @Test func aBackupBringsItAllBack() throws {
        let project = renovation()
        project.isFinished = true
        add(.expense, 3200, "瓷砖", project).recordRefund(200, on: day("2026-11-01"))
        let note = Note(title: "装修记录")
        context.insert(note)
        note.project = project
        let rule = RecurringEntry(kind: .income, name: "工资", amount: 12000, nextDate: day("2026-12-01"), recurrence: .monthly(day: 1))
        rule.asksFirst = true
        context.insert(rule)
        rule.nextDate = day("2026-12-01")
        let paid = LedgerEntry(kind: .income, amount: 12000, currencyCode: "CNY", date: day("2026-11-01"), source: .recurring)
        context.insert(paid)
        paid.recurring = rule
        paid.occurrenceDate = day("2026-11-01")
        try context.save()

        let data = try Backup.encoder().encode(Backup.make(from: context))
        let target = AppSchema.inMemoryContainer()
        try Backup.restore(Backup.read(data), into: target.mainContext)

        let projects = try target.mainContext.fetch(FetchDescriptor<Project>())
        let restored = try #require(projects.first)
        #expect(projects.count == 1 && restored.name == "装修" && restored.isFinished)
        #expect(restored.spent == 3000)
        #expect(restored.notes?.first?.title == "装修记录")
        let entry = try #require(restored.entries?.first)
        #expect(entry.refundedAmount == 200)
        #expect(entry.refundedAt == day("2026-11-01"))

        let rules = try target.mainContext.fetch(FetchDescriptor<RecurringEntry>())
        let restoredRule = try #require(rules.first)
        #expect(rules.count == 1 && restoredRule.asksFirst && restoredRule.nextDate == day("2026-12-01"))
        #expect(restoredRule.recurrence == .monthly(day: 1))
        #expect(restoredRule.entries?.first?.occurrenceDate == day("2026-11-01"))
    }

    @Test func aBackupFromBeforeTheseExistedStillRestores() throws {
        let file = BackupFile(createdAt: .now, baseCurrency: "CNY", entries: [
            .init(id: "1", kind: "expense", amount: 35, currencyCode: "CNY", rateToBase: 1, date: .now, note: "午餐", source: "manual", createdAt: .now),
        ])
        var json = try #require(JSONSerialization.jsonObject(with: Backup.encoder().encode(file)) as? [String: Any])
        json["projects"] = nil
        json["recurringEntries"] = nil
        let target = AppSchema.inMemoryContainer()
        try Backup.restore(Backup.read(JSONSerialization.data(withJSONObject: json)), into: target.mainContext)

        let entries = try target.mainContext.fetch(FetchDescriptor<LedgerEntry>())
        #expect(entries.first?.netAmount == 35)
    }
}

@MainActor
struct RecurringTests {
    private let container = AppSchema.inMemoryContainer()
    private var context: ModelContext { container.mainContext }

    private func salary(on date: String = "2026-11-15", asksFirst: Bool = false, repeats: Recurrence? = .monthly(day: 15)) -> RecurringEntry {
        let rule = RecurringEntry(kind: .income, name: "工资", amount: 12000, nextDate: day(date), recurrence: repeats)
        rule.asksFirst = asksFirst
        context.insert(rule)
        return rule
    }

    private func entries() throws -> [LedgerEntry] {
        try context.fetch(FetchDescriptor<LedgerEntry>(sortBy: [SortDescriptor(\.date)]))
    }

    @Test func itWaitsForItsDay() throws {
        let rule = salary()
        #expect(RecurringEntries.recordDue(in: context, now: day("2026-11-14", "23:59")) == 0)
        #expect(try entries().isEmpty)
        #expect(rule.nextDate == day("2026-11-15"))
    }

    @Test func onItsDayItRecordsAnEntryAndMovesOn() throws {
        let account = Account(name: "招行", kind: .debitCard)
        let category = LedgerCategory(name: "工资", kind: .income, symbol: "briefcase", colorHex: "#248A3D")
        context.insert(account)
        context.insert(category)
        let rule = salary()
        rule.account = account
        rule.category = category

        #expect(RecurringEntries.recordDue(in: context, now: day("2026-11-15", "08:00")) == 1)
        let entry = try #require(try entries().first)
        #expect(entry.kind == .income && entry.amount == 12000 && entry.note == "工资")
        #expect(entry.source == .recurring && entry.recurring === rule)
        #expect(entry.account === account && entry.category === category)
        #expect(Calendar.current.isDate(entry.date, inSameDayAs: day("2026-11-15")))
        #expect(Calendar.current.isDate(rule.nextDate, inSameDayAs: day("2026-12-15")))
    }

    @Test func runningAgainTheSameDayAddsNothing() throws {
        salary()
        RecurringEntries.recordDue(in: context, now: day("2026-11-15"))
        #expect(RecurringEntries.recordDue(in: context, now: day("2026-11-15", "20:00")) == 0)
        #expect(try entries().count == 1)
    }

    @Test func monthsAwayAreFilledInEachOnItsOwnDay() throws {
        salary(on: "2026-08-15")
        #expect(RecurringEntries.recordDue(in: context, now: day("2026-11-20")) == 4)
        let days = try entries().map { DraftParsing.day($0.date) }
        #expect(days == ["2026-08-15", "2026-09-15", "2026-10-15", "2026-11-15"])
    }

    @Test func oneThatAsksFirstIsLeftWaiting() throws {
        let rule = salary(asksFirst: true)
        #expect(RecurringEntries.recordDue(in: context, now: day("2026-12-20")) == 0)
        #expect(try entries().isEmpty)
        #expect(rule.isDue(now: day("2026-12-20")))
    }

    @Test func confirmingRecordsWhatItReallyCameTo() throws {
        let rule = salary(asksFirst: true)
        let other = Account(name: "现金", kind: .cash)
        context.insert(other)
        rule.record(amount: 11800, account: other, in: context)
        let entry = try #require(try entries().first)
        #expect(entry.amount == 11800 && entry.account === other)
        #expect(!rule.isDue(now: day("2026-11-15")))
    }

    @Test func skippingMovesOnWithoutRecording() throws {
        let rule = salary(asksFirst: true)
        rule.skip()
        #expect(try entries().isEmpty)
        #expect(Calendar.current.isDate(rule.nextDate, inSameDayAs: day("2026-12-15")))
    }

    @Test func oneThatDoesntRepeatHappensOnce() throws {
        let rule = salary(repeats: nil)
        #expect(RecurringEntries.recordDue(in: context, now: day("2027-03-01")) == 1)
        #expect(!rule.isActive)
    }

    @Test func itStopsAtItsEndDate() throws {
        var repeats = Recurrence.monthly(day: 15)
        repeats.endDate = day("2026-12-31")
        let rule = salary(repeats: repeats)
        #expect(RecurringEntries.recordDue(in: context, now: day("2027-06-01")) == 2)
        #expect(!rule.isActive)
    }

    @Test func aRuleWhoseDateWentBackDoesntRecordTheSameDayTwice() throws {
        let rule = salary()
        RecurringEntries.recordDue(in: context, now: day("2026-11-15"))
        // An older copy of the rule arriving from another device.
        rule.nextDate = day("2026-11-15")
        #expect(RecurringEntries.recordDue(in: context, now: day("2026-11-15")) == 0)
        #expect(try entries().count == 1)
    }

    @Test func deletingTheRuleKeepsWhatItRecorded() throws {
        let rule = salary()
        RecurringEntries.recordDue(in: context, now: day("2026-11-15"))
        try context.save()
        context.delete(rule)
        try context.save()
        let entry = try #require(try entries().first)
        #expect(entry.recurring == nil)
    }

    @Test func twoDevicesRecordingTheSameDayEndUpWithOne() throws {
        let rule = salary()
        func copy(createdAt: Date, note: String) -> LedgerEntry {
            let entry = LedgerEntry(kind: .income, amount: 12000, currencyCode: "CNY", date: day("2026-11-15"), note: note, source: .recurring)
            context.insert(entry)
            entry.recurring = rule
            entry.occurrenceDate = day("2026-11-15")
            entry.createdAt = createdAt
            return entry
        }
        _ = copy(createdAt: day("2026-11-15", "09:05"), note: "newer")
        _ = copy(createdAt: day("2026-11-15", "09:00"), note: "older")
        // A different occurrence stays.
        let december = copy(createdAt: day("2026-12-15"), note: "december")
        december.occurrenceDate = day("2026-12-15")
        try context.save()

        let defaults = try #require(UserDefaults(suiteName: "recurring-\(UUID().uuidString)"))
        #expect(SyncDeduper.run(in: context, defaults: defaults) == 1)
        #expect(try entries().map(\.note).sorted() == ["december", "older"])
    }

    @Test func onlyOneThatAsksFirstGetsAReminder() {
        salary(on: "2026-11-15", asksFirst: true)
        salary(on: "2026-11-16", asksFirst: false)
        let planned = NotificationScheduler.shared.plan(in: context, now: day("2026-11-01"))
            .filter { $0.target == .recurring }
        #expect(planned.count == 1)
        #expect(planned.first?.title.contains("工资") == true)
        #expect(Calendar.current.isDate(planned.first?.fireDate ?? .now, inSameDayAs: day("2026-11-15")))
    }

    @Test func noReminderOnceItsHourHasPassed() {
        salary(on: "2026-11-15", asksFirst: true)
        let planned = NotificationScheduler.shared.plan(in: context, now: day("2026-11-15", "10:00"))
        #expect(!planned.contains { $0.target == .recurring })
    }
}

struct RecurrenceFollowingTests {
    private func day(_ text: String) -> Date { DraftParsing.date(text) ?? .now }

    @Test func aMonthlyRulesDayMovesWithTheDate() {
        let rule = Recurrence.monthly(day: 6).following(day("2026-11-15"))
        #expect(rule.monthDay == 15)
        #expect(rule.nextOccurrence(after: day("2026-11-15")) == day("2026-12-15"))
    }

    @Test func theLastDayOfTheMonthStaysTheLastDay() {
        let rule = Recurrence.monthly(day: Recurrence.lastDayOfMonth).following(day("2026-11-15"))
        #expect(rule.monthDay == Recurrence.lastDayOfMonth)
    }

    @Test func otherRulesAreLeftAlone() {
        #expect(Recurrence.weekly.following(day("2026-11-15")) == .weekly)
    }
}

@MainActor
struct CaptureProjectTests {
    private let container = AppSchema.inMemoryContainer()

    private func draft(_ type: String, _ title: String) -> CaptureDraft {
        var item = ParsedItem()
        item.type = type
        item.title = title
        item.amount = "100"
        return CaptureDraft(item: item, categories: [], accounts: [], baseCurrency: "CNY")
    }

    @Test func oneExpenseTakesTheProjectFromEverythingSaid() {
        let project = Project(name: "装修")
        container.mainContext.insert(project)
        var drafts = [draft("task", "铺砖"), draft("expense", "瓷砖")]
        CaptureDraft.linkProject(in: &drafts, said: "装修那边今天买瓷砖花了 100", among: [project])
        #expect(drafts[1].project === project)
    }

    @Test func severalExpensesEachSpeakForThemselves() {
        let project = Project(name: "装修")
        container.mainContext.insert(project)
        var drafts = [draft("expense", "瓷砖"), draft("expense", "午餐")]
        CaptureDraft.linkProject(in: &drafts, said: "装修买瓷砖 100，午餐 100", among: [project])
        #expect(drafts[0].project == nil && drafts[1].project == nil)
    }
}

/// 自定义: a category named while recording.
@MainActor
struct CustomCategoryTests {
    private let container = AppSchema.inMemoryContainer()
    private var context: ModelContext { container.mainContext }

    @Test func itsAddedAtTheEndOfItsKind() throws {
        SeedData.seedDefaultsIfNeeded(context)
        let expenses = try context.fetch(FetchDescriptor<LedgerCategory>()).filter { $0.kind == .expense }
        let pets = try #require(LedgerCategory.custom(named: "  宠物 ", kind: .expense, in: context))
        #expect(pets.name == "宠物" && pets.kind == .expense && pets.parent == nil)
        #expect(pets.sortOrder == (expenses.map(\.sortOrder).max() ?? 0) + 1)
        #expect(CategoryEditorView.colors.contains(pets.colorHex))
    }

    @Test func aNameAlreadyThereIsReused() throws {
        let food = LedgerCategory(name: "Food", kind: .expense, symbol: "fork.knife", colorHex: "#D9480F")
        context.insert(food)
        #expect(LedgerCategory.custom(named: "food", kind: .expense, in: context) === food)
        #expect(try context.fetchCount(FetchDescriptor<LedgerCategory>()) == 1)
    }

    @Test func theSameNameOfTheOtherKindIsADifferentCategory() throws {
        let rent = LedgerCategory(name: "房租", kind: .expense, symbol: "house", colorHex: "#A16207")
        context.insert(rent)
        let income = try #require(LedgerCategory.custom(named: "房租", kind: .income, in: context))
        #expect(income !== rent && income.kind == .income)
    }

    @Test func aBlankNameMakesNothing() throws {
        #expect(LedgerCategory.custom(named: "   ", kind: .expense, in: context) == nil)
        #expect(try context.fetchCount(FetchDescriptor<LedgerCategory>()) == 0)
    }
}
