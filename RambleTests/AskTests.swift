import Foundation
import SwiftData
import Testing
@testable import Ramble

/// Tuesday 13 October 2026, 12:30.
private let now = DraftParsing.date("2026-10-13", time: "12:30")!

private func day(_ text: String) -> Date { DraftParsing.date(text)! }

struct PeriodResolverTests {
    private func resolve(_ text: String) -> QueryPeriod? {
        PeriodResolver.resolve(SpokenDate.normalizedNumbers(text), now: now)?.period
    }

    @Test(arguments: [
        ("这个月", "2026-10-01", "2026-11-01", "本月"),
        ("上个月", "2026-09-01", "2026-10-01", "上个月"),
        ("上上个月", "2026-08-01", "2026-09-01", "8月"),
        ("本周", "2026-10-12", "2026-10-19", "本周"),
        ("上周", "2026-10-05", "2026-10-12", "上周"),
        ("下礼拜", "2026-10-19", "2026-10-26", "下周"),
        ("今天", "2026-10-13", "2026-10-14", "今天"),
        ("昨天", "2026-10-12", "2026-10-13", "昨天"),
        ("今年", "2026-01-01", "2027-01-01", "今年"),
        ("去年", "2025-01-01", "2026-01-01", "去年"),
        ("最近七天", "2026-10-07", "2026-10-14", "最近 7 天"),
        ("近两周", "2026-09-30", "2026-10-14", "最近 2 周"),
        ("最近三个月", "2026-07-14", "2026-10-14", "最近 3 月"),
        ("九月份", "2026-09-01", "2026-10-01", "9月"),
        ("十二月", "2025-12-01", "2026-01-01", "2025年12月"),
        ("去年十月", "2025-10-01", "2025-11-01", "2025年10月"),
        ("2024年3月", "2024-03-01", "2024-04-01", "2024年3月"),
        ("上半年", "2026-01-01", "2026-07-01", "上半年"),
        ("10月1号", "2026-10-01", "2026-10-02", "10月1日"),
    ])
    func phrases(_ text: String, _ start: String, _ end: String, _ label: String) throws {
        let period = try #require(resolve(text), "\(text)")
        #expect(period.start == day(start), "\(text)")
        #expect(period.end == day(end), "\(text)")
        #expect(period.label == label, "\(text)")
    }

    @Test func noTimeWordsGiveNothing() {
        #expect(resolve("吃饭花了多少") == nil)
        #expect(resolve("装修下一步做什么") == nil)
    }

    @Test func previousPeriodsAreTheSameKind() throws {
        let month = try #require(resolve("这个月"))
        #expect(PeriodResolver.previous(month, now: now)?.start == day("2026-09-01"))
        let week = try #require(resolve("本周"))
        #expect(PeriodResolver.previous(week, now: now)?.start == day("2026-10-05"))
        let rolling = try #require(resolve("最近7天"))
        let before = try #require(PeriodResolver.previous(rolling, now: now))
        #expect(before.end == rolling.start && before.start == day("2026-09-30"))
    }

    @Test func aiPresetsAndCustomRanges() throws {
        #expect(PeriodResolver.preset("lastMonth", now: now)?.start == day("2026-09-01"))
        let custom = try #require(PeriodResolver.preset("custom", from: "2026-10-01", to: "2026-10-07", now: now))
        #expect(custom.start == day("2026-10-01") && custom.end == day("2026-10-08"))
        #expect(PeriodResolver.preset("custom", from: "nonsense", now: now) == nil)
        #expect(PeriodResolver.preset("none", now: now) == nil)
    }
}

struct QuestionParserTests {
    private let categories = [
        CategoryInfo(name: "餐饮", isIncome: false, seedKey: "food"),
        CategoryInfo(name: "交通", isIncome: false, seedKey: "transport"),
        CategoryInfo(name: "购物", isIncome: false, seedKey: "shopping"),
        CategoryInfo(name: "咖啡", isIncome: false, parent: "餐饮"),
        CategoryInfo(name: "工资", isIncome: true, seedKey: "salary"),
    ]

    private func parse(_ question: String) -> QuestionParser.Result {
        QuestionParser.parse(question, categories: categories, now: now)
    }

    @Test func spendingOnACategory() throws {
        let result = parse("这个月吃饭花了多少")
        let plan = try #require(result.plan)
        #expect(result.confident)
        #expect(plan.subject == .expense && plan.measure == .total && plan.categories == ["餐饮"])
        #expect(plan.period?.label == "本月")
    }

    @Test func theirOwnCategoryNamesWin() throws {
        let plan = try #require(parse("上个月咖啡花了多少钱？").plan)
        #expect(plan.categories == ["咖啡"] && plan.period?.label == "上个月")
    }

    @Test func merchantsAreSearchedThenFallBackToTheirCategory() throws {
        let result = parse("今年打车一共花了多少")
        let plan = try #require(result.plan)
        #expect(result.confident)
        #expect(plan.keywords == ["打车"] && plan.categories == ["交通"] && plan.period?.label == "今年")
    }

    @Test func whereTheMoneyWent() throws {
        let result = parse("上个月钱主要花在哪了")
        #expect(result.confident)
        #expect(result.plan?.measure == .top)
        #expect(parse("上个月花最多的是哪类").plan?.measure == .top)
        #expect(parse("这个月最贵的一笔是什么").plan?.measure == .biggest)
        #expect(parse("这个月吃饭跟上个月比怎么样").plan?.measure == .compare)
    }

    @Test func incomeAndBalance() throws {
        let salary = try #require(parse("九月工资多少").plan)
        #expect(salary.subject == .income && salary.categories == ["工资"])
        #expect(parse("今年收入多少").plan?.subject == .income)
        #expect(parse("这个月结余多少").plan?.subject == .balance)
    }

    @Test func tasksBillsAndExpiries() throws {
        let week = try #require(parse("这周还有哪些待办").plan)
        #expect(week.subject == .tasks && week.taskState == .open && week.measure == .list && week.period?.label == "本周")
        #expect(parse("上周完成了几件事").plan?.taskState == .done)
        #expect(parse("有哪些过期没做的待办").plan?.taskState == .overdue)
        #expect(parse("下个月有哪些账单要还").plan?.subject == .bills)
        let expiry = parse("最近有什么要到期的")
        #expect(expiry.plan?.subject == .expiries && expiry.confident)
    }

    @Test func questionsTheRulesCantReadGoToAI() {
        // 「血脂」 isn't money or a record type the rules know.
        let result = parse("血脂多少")
        #expect(!result.confident)
        #expect(result.plan?.subject == .notes)
        #expect(!parse("装修那边下一步要做什么").confident)
    }

    @Test func questionsAreToldApartFromThingsToRecord() {
        #expect(QuestionParser.looksLikeQuestion("这个月吃饭花了多少"))
        #expect(QuestionParser.looksLikeQuestion("下周有账单吗"))
        #expect(!QuestionParser.looksLikeQuestion("中午吃饭花了三十五"))
        #expect(!QuestionParser.looksLikeQuestion("明天下午三点开会"))
    }
}

@MainActor
struct QueryRunnerTests {
    private let container = AppSchema.makeContainer(inMemory: true)

    private func library() throws -> ModelContext {
        let context = container.mainContext
        let food = LedgerCategory(name: "餐饮", kind: .expense, symbol: "fork.knife", colorHex: "#D9480F", seedKey: "food")
        let coffee = LedgerCategory(name: "咖啡", kind: .expense, symbol: "cup.and.saucer", colorHex: "#A2845E")
        coffee.parent = food
        let transport = LedgerCategory(name: "交通", kind: .expense, symbol: "tram", colorHex: "#0A66D8", seedKey: "transport")
        let salary = LedgerCategory(name: "工资", kind: .income, symbol: "briefcase", colorHex: "#248A3D", seedKey: "salary")
        [food, coffee, transport, salary].forEach(context.insert)

        func add(_ kind: EntryKind, _ amount: Decimal, _ category: LedgerCategory, _ date: String, _ note: String = "") {
            let entry = LedgerEntry(kind: kind, amount: amount, currencyCode: "CNY", date: DraftParsing.date(date, time: "12:00")!, note: note)
            context.insert(entry)
            entry.category = category
        }
        add(.expense, 35, food, "2026-10-13", "午餐")
        add(.expense, 28, coffee, "2026-10-12", "拿铁")
        add(.expense, 22, transport, "2026-10-10", "打车回家")
        add(.expense, 4, transport, "2026-10-09", "地铁")
        add(.expense, 600, food, "2026-10-03", "请客吃饭")
        add(.expense, 300, food, "2026-09-20")
        add(.income, 12000, salary, "2026-10-10")
        let budget = Budget(amount: 1000)
        context.insert(budget)
        budget.category = food

        let overdue = TaskItem(title: "交房租", dueDate: day("2026-10-11"))
        let today = TaskItem(title: "交季度报告", dueDate: DraftParsing.date("2026-10-13", time: "18:00"), hasDueTime: true)
        let friday = TaskItem(title: "取快递", dueDate: day("2026-10-16"))
        let done = TaskItem(title: "体检", dueDate: day("2026-10-12"))
        done.isCompleted = true
        done.completedAt = DraftParsing.date("2026-10-12", time: "10:00")
        [overdue, today, friday, done].forEach(context.insert)

        let note = Note(title: "体检")
        context.insert(note)
        let entry = NoteEntry(text: "体检报告出来了，甘油三酯2.1偏高，三个月后复查血脂。", date: day("2026-10-10"))
        context.insert(entry)
        entry.note = note
        try context.save()
        return context
    }

    private func ask(_ question: String, context: ModelContext) throws -> AskAnswer {
        let categories = try context.fetch(FetchDescriptor<LedgerCategory>()).map {
            CategoryInfo(name: $0.name, isIncome: $0.kind == .income, parent: $0.parent?.name, seedKey: $0.seedKey)
        }
        let plan = try #require(QuestionParser.parse(question, categories: categories, now: now).plan)
        return QueryRunner.run(plan, context: context, now: now)
    }

    @Test func spendingWithComparisonAndBudget() throws {
        let context = try library()
        let answer = try ask("这个月吃饭花了多少", context: context)
        #expect(answer.headline == "本月「餐饮」支出 ¥663.00，共 3 笔。")
        // September's only meal was on the 20th, after the 13 days compared: no comparison to make.
        #expect(!answer.details.contains { $0.hasPrefix("比") })
        #expect(answer.details.contains("预算还剩 ¥337.00"))
    }

    @Test func aRunningMonthIsComparedWithTheSameDays() throws {
        let context = try library()
        let food = try #require(try context.fetch(FetchDescriptor<LedgerCategory>()).first { $0.name == "餐饮" })
        let early = LedgerEntry(kind: .expense, amount: 100, currencyCode: "CNY", date: DraftParsing.date("2026-09-05", time: "12:00")!)
        context.insert(early)
        early.category = food
        try context.save()
        let answer = try ask("这个月吃饭花了多少", context: context)
        #expect(answer.details.contains("比上个月同期多 ¥563.00（+563%）"))
        // A finished month is compared whole.
        #expect(try ask("9月吃饭花了多少", context: context).headline == "9月「餐饮」支出 ¥400.00，共 2 笔。")
    }

    @Test func subcategoriesAndMerchants() throws {
        let context = try library()
        #expect(try ask("这个月咖啡花了多少", context: context).headline == "本月「咖啡」支出 ¥28.00，共 1 笔。")
        // 「打车」 is in a note; 「地铁」 isn't counted.
        #expect(try ask("这个月打车花了多少", context: context).headline == "本月「打车」支出 ¥22.00，共 1 笔。")
    }

    @Test func whereItWent() throws {
        let context = try library()
        let answer = try ask("这个月钱主要花在哪", context: context)
        #expect(answer.bars.map(\.label) == ["餐饮", "交通"])
        #expect(answer.headline.hasPrefix("本月花得最多的是餐饮 ¥663.00"))
        let biggest = try ask("这个月最贵的一笔是什么", context: context)
        #expect(biggest.headline.contains("请客吃饭") && biggest.items.count == 5)
    }

    @Test func incomeBalanceTasksAndNotes() throws {
        let context = try library()
        #expect(try ask("这个月工资多少", context: context).headline == "本月工资收入 ¥12,000.00，共 1 笔。")
        #expect(try ask("这个月结余多少", context: context).headline == "本月收入 ¥12,000.00，支出 ¥689.00，结余 ¥11,311.00。")
        let tasks = try ask("今天还有什么待办", context: context)
        #expect(tasks.items.map(\.title) == ["交房租", "交季度报告"])
        let week = try ask("这周有哪些待办", context: context)
        #expect(week.items.map(\.title) == ["交房租", "交季度报告", "取快递"])
        #expect(try ask("这周完成了几件待办", context: context).headline == "本周完成了 1 件待办。")
        let notes = QueryRunner.run(QueryPlan(subject: .notes, measure: .list, keywords: ["血脂"]), context: context, now: now)
        #expect(notes.items.count == 1 && notes.items[0].subtitle.hasPrefix("体检"))
        #expect(try ask("上周花了多少", context: context).headline.hasPrefix("上周支出 ¥26.00"))
        #expect(try ask("去年花了多少", context: context).headline == "去年没有支出记录。")
    }
}

@MainActor
struct ReportTests {
    private let container = AppSchema.makeContainer(inMemory: true)

    @Test func lastWeekAgainstTheWeekBefore() throws {
        let context = container.mainContext
        let food = LedgerCategory(name: "餐饮", kind: .expense, symbol: "fork.knife", colorHex: "#D9480F")
        let shopping = LedgerCategory(name: "购物", kind: .expense, symbol: "bag", colorHex: "#C2185B")
        let travel = LedgerCategory(name: "旅行", kind: .expense, symbol: "airplane", colorHex: "#248A3D")
        [food, shopping, travel].forEach(context.insert)
        func add(_ amount: Decimal, _ category: LedgerCategory, _ date: String, _ note: String = "") {
            let entry = LedgerEntry(kind: .expense, amount: amount, currencyCode: "CNY", date: DraftParsing.date(date, time: "12:00")!, note: note)
            context.insert(entry)
            entry.category = category
        }
        // Week of 5 Oct (last week) and of 28 Sep (the one before).
        add(200, food, "2026-10-06")
        add(500, shopping, "2026-10-07", "羽绒服")
        add(1200, travel, "2026-10-10", "机票")
        add(180, food, "2026-09-29")
        add(100, shopping, "2026-09-30")
        let done = TaskItem(title: "交报告", dueDate: day("2026-10-08"))
        done.isCompleted = true
        done.completedAt = DraftParsing.date("2026-10-08", time: "15:00")
        context.insert(done)
        context.insert(TaskItem(title: "交房租", dueDate: day("2026-10-11")))
        context.insert(Bill(name: "信用卡还款", kind: .creditCard, amount: 2180, nextDueDate: day("2026-10-15")))
        try context.save()

        // Tuesday: the week has barely begun, so last week opens by default.
        let period = ReportBuilder.defaultPeriod(.week, now: now)
        #expect(period.label == "上周" && period.start == day("2026-10-05"))
        let report = ReportBuilder.make(.week, period: period, context: context, now: now)
        #expect(report.expense == 1900 && report.previousExpense == 280 && report.expenseCount == 3)
        #expect(report.categories.map(\.name) == ["旅行", "购物", "餐饮"])
        #expect(report.biggest.first?.title == "机票")
        #expect(report.tasksCompleted == 1 && report.overdueOpen == 1)
        #expect(report.upcomingBills.map(\.name) == ["信用卡还款"])
        #expect(report.highlights.first == "支出比前一周多 ¥1,620.00（+579%）")
        #expect(report.highlights.contains("购物比前一周多 ¥400.00（+400%），值得留意"))
        #expect(report.highlights.contains("新出现一笔大项：旅行 ¥1,200.00"))
        #expect(report.highlights.contains("完成了 1 件待办，还有 1 件已过期"))
        #expect(report.aiSummaryInput.contains("旅行 ¥1,200.00") && !report.aiSummaryInput.contains("羽绒服"))
    }

    @Test func monthsAndNavigation() {
        let month = ReportBuilder.defaultPeriod(.month, now: now)
        #expect(month.label == "本月")
        let previous = ReportBuilder.shifted(month, kind: .month, by: -1, now: now)
        #expect(previous.label == "9月" && previous.start == day("2026-09-01"))
        let early = ReportBuilder.defaultPeriod(.month, now: DraftParsing.date("2026-11-02", time: "09:00")!)
        #expect(early.start == day("2026-10-01"))
    }
}

struct ReportReminderTests {
    @Test func mondaysAndFirstsAtNine() throws {
        let reminders = ReminderPlanner.reportReminders(weekly: true, monthly: true, now: now)
        let weekly = try #require(reminders.first { $0.targetID == "week" })
        #expect(weekly.fireDate == DraftParsing.date("2026-10-19", time: "09:00") && weekly.target == .report)
        let monthly = try #require(reminders.first { $0.targetID == "month" })
        #expect(monthly.fireDate == DraftParsing.date("2026-11-01", time: "09:00") && monthly.title == "10月月报")
        #expect(ReminderPlanner.reportReminders(weekly: false, monthly: false, now: now).isEmpty)
    }

    @MainActor
    @Test func linksAndNotificationsOpenTheReport() {
        let router = AppRouter.shared
        defer { router.pendingReport = nil; router.pendingAsk = nil }
        router.open(.report, id: "month")
        #expect(router.pendingReport == .month)
        #expect(router.open(URL(string: "ramble://ask?q=%E8%BF%99%E4%B8%AA%E6%9C%88%E8%8A%B1%E4%BA%86%E5%A4%9A%E5%B0%91")!))
        #expect(router.pendingAsk?.question == "这个月花了多少")
    }
}

struct AIQueryPlanTests {
    private let categories = [
        CategoryInfo(name: "餐饮", isIncome: false, seedKey: "food"),
        CategoryInfo(name: "交通", isIncome: false, seedKey: "transport"),
        CategoryInfo(name: "工资", isIncome: true, seedKey: "salary"),
    ]

    @Test func aiPlansAreCheckedAgainstWhatThePersonHas() throws {
        let json = #"{"subject":"expense","measure":"total","period":"custom","from":"2026-10-01","to":"2026-10-07","categories":["交通","出租车","工资"],"keywords":[" 打车 ",""],"taskState":"open"}"#
        let raw = try JSONDecoder().decode(AIQueryPlan.self, from: Data(json.utf8))
        let plan = raw.plan(categories: categories, now: now)
        #expect(plan.subject == .expense && plan.measure == .total)
        #expect(plan.categories == ["交通"])
        #expect(plan.keywords == ["打车"])
        #expect(plan.period?.start == day("2026-10-01") && plan.period?.end == day("2026-10-08"))
    }

    @Test func missingOrOddFieldsFallBack() throws {
        let raw = try JSONDecoder().decode(AIQueryPlan.self, from: Data(#"{"subject":"weather","period":"someday"}"#.utf8))
        let plan = raw.plan(categories: categories, now: now)
        #expect(plan.subject == .notes && plan.period == nil && plan.measure == .total)
    }

    @Test func theSchemaOffersEveryOption() {
        let schema = AskEngine.planSchema.jsonSchema
        let properties = schema["properties"] as? [String: Any]
        let subject = properties?["subject"] as? [String: Any]
        #expect((subject?["enum"] as? [String]) == QueryPlan.Subject.allCases.map(\.rawValue))
        #expect(AskEngine.planInstructions(categories: categories, now: now).contains("Expense categories: 餐饮, 交通"))
    }
}

/// 问一问 keeps what was asked, conversation by conversation.
struct AskHistoryTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "ask-history-\(UUID().uuidString).json")
    }

    private func answer() -> AskAnswer {
        var answer = AskAnswer(headline: "本月 · 餐饮 ¥820，共 12 笔。")
        answer.details = ["日均 ¥27"]
        answer.bars = [.init(label: "餐饮", amount: Decimal(string: "820.5")!, fraction: 0.4, colorHex: "#D9480F", change: "+¥20")]
        answer.items = [.init(id: "a", title: "午餐", subtitle: "10月3日", trailing: "¥35", link: .task("x"))]
        answer.source = .ai(.cloud(.anthropic))
        answer.plan = QueryPlan(subject: .expense, measure: .total, categories: ["餐饮"])
        return answer
    }

    private func record(_ question: String, at date: Date = .now) -> AskRecord {
        AskRecord(date: date, question: question, answer: answer(), currency: "CNY")
    }

    @Test func answersComeBackAsTheyWere() {
        let url = temporaryURL()
        defer { AskHistory.clear(at: url) }
        let record = AskRecord(date: .now, question: "这个月吃饭花了多少", answer: answer(), currency: "CNY", seconds: 2.5)
        AskHistory.add(record, to: UUID(), at: url)
        let loaded = AskHistory.load(from: url)
        #expect(loaded.first?.records == [record])
        #expect(loaded.first?.title == "这个月吃饭花了多少")
        #expect(loaded.first?.records.first?.answer.plan?.subject == .expense)
    }

    @Test func questionsStayInTheirConversationAndTheLatestComesFirst() {
        let url = temporaryURL()
        defer { AskHistory.clear(at: url) }
        let first = UUID(), second = UUID()
        AskHistory.add(record("一"), to: first, at: url)
        AskHistory.add(record("二"), to: second, at: url)
        #expect(AskHistory.load(from: url).map(\.id) == [second, first])
        AskHistory.add(record("三"), to: first, at: url)
        let loaded = AskHistory.load(from: url)
        #expect(loaded.map(\.id) == [first, second])
        #expect(loaded[0].records.map(\.question) == ["一", "三"])
    }

    @Test func deletingAQuestionKeepsThePlaceAndTheLastOneTakesTheConversation() {
        let url = temporaryURL()
        defer { AskHistory.clear(at: url) }
        let first = UUID(), second = UUID()
        AskHistory.add(record("一"), to: first, at: url)
        AskHistory.add(record("二"), to: first, at: url)
        AskHistory.add(record("三"), to: second, at: url)
        let kept = AskHistory.load(from: url)[1].records.suffix(1)
        AskHistory.update(first, records: Array(kept), at: url)
        #expect(AskHistory.load(from: url).map(\.id) == [second, first])
        #expect(AskHistory.load(from: url)[1].records.map(\.question) == ["二"])
        AskHistory.update(first, records: [], at: url)
        #expect(AskHistory.load(from: url).map(\.id) == [second])
    }

    @Test func keepsTheNewestQuestions() {
        let url = temporaryURL()
        defer { AskHistory.clear(at: url) }
        let questions = (0..<(AskHistory.limit + 30)).map { record("问题 \($0)") }
        // Newest conversation first: the latest 100 questions, then the rest, then one with no room left.
        let conversations = [AskConversation(records: Array(questions.suffix(100))),
                             AskConversation(records: Array(questions.prefix(AskHistory.limit - 70))),
                             AskConversation(records: [record("更早")])]
        AskHistory.save(conversations, to: url)
        let loaded = AskHistory.load(from: url)
        #expect(loaded.count == 2)
        #expect(loaded.flatMap(\.records).count == AskHistory.limit)
        #expect(loaded[1].records.first?.question == "问题 30")
        #expect(loaded[1].records.last?.question == "问题 \(AskHistory.limit - 71)")
    }

    @Test func onlyARecentConversationIsCarriedOn() {
        let url = temporaryURL()
        defer { AskHistory.clear(at: url) }
        let id = UUID()
        AskHistory.add(record("一", at: now), to: id, at: url)
        #expect(AskHistory.resumable(now: now.addingTimeInterval(29 * 60), from: url)?.id == id)
        #expect(AskHistory.resumable(now: now.addingTimeInterval(31 * 60), from: url) == nil)
    }

    @Test func theOldListBecomesConversations() throws {
        let url = temporaryURL(), legacy = temporaryURL()
        defer { AskHistory.clear(at: url); AskHistory.clear(at: legacy) }
        let old = [record("一", at: now), record("二", at: now.addingTimeInterval(10 * 60)),
                   record("三", at: now.addingTimeInterval(3 * 3600)), record("四", at: now.addingTimeInterval(86400))]
        try JSONEncoder().encode(old).write(to: legacy)

        let loaded = AskHistory.load(from: url, legacy: legacy)
        #expect(loaded.map { $0.records.map(\.question) } == [["四"], ["三"], ["一", "二"]])
        #expect(!FileManager.default.fileExists(atPath: legacy.path()))
        #expect(AskHistory.load(from: url, legacy: legacy) == loaded)
        // Cleared stays cleared.
        AskHistory.clear(at: url)
        #expect(AskHistory.load(from: url, legacy: legacy).isEmpty)
    }

    @Test func clearingRemovesEverything() {
        let url = temporaryURL()
        AskHistory.add(record("q"), to: UUID(), at: url)
        AskHistory.clear(at: url)
        #expect(AskHistory.load(from: url).isEmpty)
    }

    @Test func damagedFileReadsAsEmpty() throws {
        let url = temporaryURL()
        defer { AskHistory.clear(at: url) }
        try Data("not json".utf8).write(to: url)
        #expect(AskHistory.load(from: url).isEmpty)
    }
}

/// When to ask for a rating.
struct ReviewPromptTests {
    private func defaults() throws -> UserDefaults {
        let name = "review-tests-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    @Test func asksAfterAFewCapturesOncePerVersion() throws {
        let defaults = try defaults()
        for _ in 1..<ReviewPrompt.capturesNeeded {
            #expect(!ReviewPrompt.captureSaved(version: "1.2", defaults: defaults))
        }
        #expect(ReviewPrompt.captureSaved(version: "1.2", defaults: defaults))
        // Not again in this version, however many more.
        for _ in 0..<(ReviewPrompt.capturesNeeded * 2) {
            #expect(!ReviewPrompt.captureSaved(version: "1.2", defaults: defaults))
        }
        // The next version has earned it already.
        #expect(ReviewPrompt.captureSaved(version: "1.3", defaults: defaults))
    }

    @Test func aNewVersionStartsCountingAfterAsking() throws {
        let defaults = try defaults()
        for _ in 0..<ReviewPrompt.capturesNeeded { _ = ReviewPrompt.captureSaved(version: "1.2", defaults: defaults) }
        #expect(!ReviewPrompt.captureSaved(version: "1.3", defaults: defaults))
    }
}

/// A question in a conversation says only what changes.
struct FollowUpTests {
    private let categories = [
        CategoryInfo(name: "餐饮", isIncome: false, seedKey: "food"),
        CategoryInfo(name: "交通", isIncome: false, seedKey: "transport"),
        CategoryInfo(name: "购物", isIncome: false, seedKey: "shopping"),
        CategoryInfo(name: "工资", isIncome: true, seedKey: "salary"),
    ]

    private func parse(_ question: String, after earlier: String) -> QuestionParser.Result {
        let previous = QuestionParser.parse(earlier, categories: categories, now: now).plan
        return QuestionParser.parse(question, categories: categories, now: now, after: previous)
    }

    @Test(arguments: ["上个月", "那上个月呢", "上一个月呢", "上个月的", "上月呢"])
    func theTimeChanges(_ question: String) throws {
        let result = parse(question, after: "餐饮花了多少钱")
        let plan = try #require(result.plan)
        #expect(result.confident)
        #expect(plan.subject == .expense && plan.measure == .total && plan.categories == ["餐饮"])
        #expect(plan.period?.label == "上个月")
    }

    @Test func oneAfterAnother() throws {
        let previous = try #require(parse("再上个月呢", after: "上个月吃饭花了多少").plan)
        #expect(previous.categories == ["餐饮"] && previous.period?.start == day("2026-08-01"))
        let next = try #require(QuestionParser.parse("交通呢", categories: categories, now: now, after: previous).plan)
        #expect(next.categories == ["交通"] && next.period?.start == day("2026-08-01"))
    }

    /// 「上个月有哪些收入」 then 「餐饮花了多少钱」 was answered for this month.
    @Test func anotherQuestionAboutTheSameTime() throws {
        let plan = try #require(parse("餐饮花了多少钱", after: "上个月有哪些收入").plan)
        #expect(plan.subject == .expense && plan.measure == .total && plan.categories == ["餐饮"])
        #expect(plan.period?.label == "上个月")
    }

    @Test func somethingElseAskedTheSameWay() throws {
        let transport = try #require(parse("那交通呢", after: "上个月吃饭最贵的一笔").plan)
        #expect(transport.categories == ["交通"] && transport.measure == .biggest && transport.period?.label == "上个月")
        let merchant = try #require(parse("打车呢", after: "上个月吃饭花了多少").plan)
        #expect(merchant.keywords == ["打车"] && merchant.categories == ["交通"] && merchant.period?.label == "上个月")
        let income = try #require(parse("工资呢", after: "上个月吃饭花了多少").plan)
        #expect(income.subject == .income && income.categories == ["工资"] && income.period?.label == "上个月")
        // 「花在哪」 is about many categories; one category is just its total.
        #expect(parse("交通呢", after: "上个月钱主要花在哪").plan?.measure == .total)
    }

    @Test func anotherWayToLookAtIt() throws {
        for (question, measure) in [("最贵的一笔呢", QueryPlan.Measure.biggest), ("平均每天呢", .average), ("明细", .list), ("有几笔", .count)] {
            let result = parse(question, after: "上个月吃饭花了多少")
            let plan = try #require(result.plan, "\(question)")
            #expect(result.confident, "\(question)")
            #expect(plan.measure == measure && plan.categories == ["餐饮"] && plan.period?.label == "上个月", "\(question)")
        }
        #expect(parse("平均每天呢", after: "上个月收入多少").plan?.subject == .income)
    }

    @Test func comparingKeepsWhatWasAsked() throws {
        let plan = try #require(parse("和上个月比呢", after: "这个月吃饭花了多少").plan)
        #expect(plan.measure == .compare && plan.categories == ["餐饮"] && plan.period?.label == "本月")
        // No time said before means this month, and it stays that way.
        let implied = try #require(parse("比上个月多吗", after: "吃饭花了多少").plan)
        #expect(implied.measure == .compare && implied.period == nil)
        // Both said, on their own: the later one is compared with the earlier.
        let both = try #require(QuestionParser.parse("这个月比上个月花得多吗", categories: categories, now: now).plan)
        #expect(both.measure == .compare && both.period?.label == "本月")
    }

    @Test func aDifferentTopicLeavesTheTimeUnlessTheySayOtherwise() throws {
        let income = try #require(parse("收入呢", after: "上个月吃饭花了多少").plan)
        #expect(income.subject == .income && income.categories.isEmpty && income.period?.label == "上个月")
        let marked = try #require(parse("待办呢", after: "这周花了多少").plan)
        #expect(marked.subject == .tasks && marked.period?.label == "本周")
        let new = try #require(parse("有哪些待办", after: "上个月花了多少").plan)
        #expect(new.subject == .tasks && new.period == nil)
        let done = try #require(parse("这周呢", after: "上周完成了几件事").plan)
        #expect(done.subject == .tasks && done.taskState == .done && done.period?.label == "本周")
    }

    @Test func aQuestionThatStandsAloneDoes() throws {
        let tasks = try #require(parse("这周还有哪些待办", after: "上个月吃饭花了多少").plan)
        #expect(tasks.subject == .tasks && tasks.measure == .list && tasks.period?.label == "本周" && tasks.categories.isEmpty)
        // Nothing to go on: AI reads it, without being told about the last one.
        let new = parse("血脂多少", after: "上个月吃饭花了多少")
        #expect(!new.confident && !new.carriesOn && new.plan?.subject == .notes && new.plan?.period == nil)
        #expect(parse("装修那边下一步要做什么", after: "上个月吃饭花了多少").carriesOn == false)
        // Saying nothing asks nothing.
        #expect(parse("呢", after: "上个月吃饭花了多少").plan == nil)
    }

    @Test func wordsTheRulesDontKnowGoToAI() throws {
        let result = parse("那胖东来呢", after: "上个月吃饭花了多少")
        let plan = try #require(result.plan)
        #expect(!result.confident && result.carriesOn)
        #expect(plan.subject == .expense && plan.keywords == ["胖东来"] && plan.categories.isEmpty && plan.period?.label == "上个月")
        // AI is the only reader of other languages, so it always hears what came before.
        #expect(parse("and last week?", after: "上个月吃饭花了多少").carriesOn)
        // After a question about notes, a time alone still needs AI to hear what was asked.
        #expect(parse("上个月", after: "笔记里记过什么").carriesOn)
    }

    @Test func aTimeOnItsOwnWithNothingBeforeIsAboutMoney() throws {
        let past = QuestionParser.parse("上个月", categories: categories, now: now)
        #expect(past.confident && past.plan?.subject == .expense && past.plan?.period?.label == "上个月")
        // Still to come: to-dos or bills as likely as money. AI decides, but the time is certain.
        let coming = QuestionParser.parse("下个月", categories: categories, now: now)
        #expect(!coming.confident && coming.plan == nil && coming.period?.label == "下个月")
    }

    @Test func aiHearsWhatTheLastQuestionLookedUp() throws {
        let previous = try #require(parse("9月吃饭花了多少", after: "").plan)
        let instructions = AskEngine.planInstructions(categories: categories, now: now, after: previous)
        #expect(instructions.contains(#""from":"2026-09-01""#) && instructions.contains(#""to":"2026-09-30""#))
        #expect(instructions.contains(#""categories":["餐饮"]"#) && instructions.contains(#""period":"custom""#))
        #expect(!AskEngine.planInstructions(categories: categories, now: now).contains("The question before"))
    }
}

/// Follow-ups all the way to the answer, without AI.
@MainActor
struct AskFollowUpTests {
    private let container = AppSchema.makeContainer(inMemory: true)

    private func library() throws -> ModelContext {
        let context = container.mainContext
        let food = LedgerCategory(name: "餐饮", kind: .expense, symbol: "fork.knife", colorHex: "#D9480F", seedKey: "food")
        let transport = LedgerCategory(name: "交通", kind: .expense, symbol: "tram", colorHex: "#0A66D8", seedKey: "transport")
        [food, transport].forEach(context.insert)
        func add(_ amount: Decimal, _ category: LedgerCategory, _ date: String) {
            let entry = LedgerEntry(kind: .expense, amount: amount, currencyCode: "CNY", date: DraftParsing.date(date, time: "12:00")!)
            context.insert(entry)
            entry.category = category
        }
        add(35, food, "2026-10-13")
        add(300, food, "2026-09-20")
        add(22, transport, "2026-09-10")
        add(4, transport, "2026-10-09")
        try context.save()
        return context
    }

    private func answered(_ question: String, after previous: AskRecord? = nil, on date: Date = now, context: ModelContext) async throws -> AskRecord {
        let answer = try await AskEngine.ask(question, after: previous, context: context, now: date)
        return AskRecord(date: date, question: question, answer: answer, currency: "CNY")
    }

    @Test func theConversationInTheScreenshot() async throws {
        let context = try library()
        let food = try await answered("餐饮花了多少钱", context: context)
        #expect(food.answer.headline == "本月「餐饮」支出 ¥35.00，共 1 笔。")
        let lastMonth = try await answered("上个月", after: food, context: context)
        #expect(lastMonth.answer.headline == "上个月「餐饮」支出 ¥300.00，共 1 笔。")
        #expect(lastMonth.answer.source == .rules)
        let transport = try await answered("交通呢", after: lastMonth, context: context)
        #expect(transport.answer.headline == "上个月「交通」支出 ¥22.00，共 1 笔。")
    }

    /// A word with no category of its own used to be given everything spent in the period.
    @Test func aWordNothingMatchesFindsNothing() throws {
        let context = try library()
        let plan = QueryPlan(subject: .expense, period: PeriodResolver.preset("lastMonth", now: now), keywords: ["胖东来"])
        #expect(QueryRunner.run(plan, context: context, now: now).headline == "上个月没有「胖东来」支出记录。")
    }

    @Test func theTimeDoesNotCarryOverToAnotherDay() async throws {
        let context = try library()
        let lastMonth = try await answered("上个月吃饭花了多少", on: now.addingTimeInterval(-86400), context: context)
        let transport = try await answered("交通呢", after: lastMonth, context: context)
        #expect(transport.answer.headline == "本月「交通」支出 ¥4.00，共 1 笔。")
    }
}
