import Foundation
import SwiftData

// MARK: - Periods

/// A stretch of time a question or report is about, with how to say it.
nonisolated struct QueryPeriod: Codable, Equatable {
    enum Unit: String, Codable { case day, week, month, year, halfYear, rolling, all }

    var start: Date
    var end: Date
    var unit: Unit
    /// "本月", "10月", "最近 7 天".
    var label: String

    var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }

    func holds(_ date: Date) -> Bool { date >= start && date < end }
}

/// Turns 「这个月」「上周」「最近3个月」「10月」「去年」 into dates. Weeks start on Monday.
nonisolated enum PeriodResolver {
    static var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    static func day(_ date: Date) -> QueryPeriod {
        let start = calendar.startOfDay(for: date)
        return QueryPeriod(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!, unit: .day,
                           label: date.formatted(.dateTime.month().day()))
    }

    static func week(containing date: Date, label: String? = nil) -> QueryPeriod {
        let interval = calendar.dateInterval(of: .weekOfYear, for: date)!
        let last = calendar.date(byAdding: .day, value: -1, to: interval.end)!
        return QueryPeriod(start: interval.start, end: interval.end, unit: .week,
                           label: label ?? "\(interval.start.formatted(.dateTime.month().day()))–\(last.formatted(.dateTime.month().day()))")
    }

    static func month(containing date: Date, now: Date = .now, label: String? = nil) -> QueryPeriod {
        let interval = calendar.dateInterval(of: .month, for: date)!
        return QueryPeriod(start: interval.start, end: interval.end, unit: .month, label: label ?? monthLabel(interval.start, now: now))
    }

    static func year(containing date: Date, label: String? = nil) -> QueryPeriod {
        let interval = calendar.dateInterval(of: .year, for: date)!
        return QueryPeriod(start: interval.start, end: interval.end, unit: .year,
                           label: label ?? date.formatted(.dateTime.year()))
    }

    /// 「10月」 this year, 「2025年10月」 before; "Oct" / "Oct 2025" in English.
    static func monthLabel(_ date: Date, now: Date) -> String {
        let year = calendar.component(.year, from: date)
        return year == calendar.component(.year, from: now) ? date.formatted(.dateTime.month(.abbreviated))
                                                            : date.formatted(.dateTime.year().month(.abbreviated))
    }

    /// The last `days` days, today included.
    static func rolling(days: Int, now: Date, label: String) -> QueryPeriod {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        return QueryPeriod(start: calendar.date(byAdding: .day, value: -days, to: end)!, end: end, unit: .rolling, label: label)
    }

    static func allTime(now: Date) -> QueryPeriod {
        QueryPeriod(start: .distantPast, end: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!,
                    unit: .all, label: String(localized: "到目前为止"))
    }

    /// The period just before, of the same kind: last month for a month, the 7 days before for "最近 7 天".
    static func previous(_ period: QueryPeriod, now: Date = .now) -> QueryPeriod? {
        switch period.unit {
        case .day:
            return day(calendar.date(byAdding: .day, value: -1, to: period.start)!)
        case .week:
            return week(containing: calendar.date(byAdding: .day, value: -7, to: period.start)!)
        case .month:
            return month(containing: calendar.date(byAdding: .month, value: -1, to: period.start)!, now: now)
        case .year:
            return year(containing: calendar.date(byAdding: .year, value: -1, to: period.start)!)
        case .halfYear, .rolling:
            let length = period.end.timeIntervalSince(period.start)
            return QueryPeriod(start: period.start.addingTimeInterval(-length), end: period.start, unit: .rolling,
                               label: String(localized: "之前同样长的时间"))
        case .all:
            return nil
        }
    }

    /// While `period` is still running, the matching stretch of the one before it (上个月同期):
    /// the first 13 days of September against the first 13 of October.
    static func samePoint(in previous: QueryPeriod, for period: QueryPeriod, now: Date) -> QueryPeriod {
        guard period.holds(now), [.week, .month, .year].contains(period.unit) else { return previous }
        let cal = calendar
        let elapsed = cal.dateComponents([.day], from: period.start, to: cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!).day ?? 0
        var cut = previous
        cut.end = min(previous.end, cal.date(byAdding: .day, value: elapsed, to: previous.start)!)
        cut.label = previous.label + String(localized: "同期")
        return cut
    }

    /// Presets the AI picks from.
    static let presets = ["none", "today", "yesterday", "tomorrow", "thisWeek", "lastWeek", "nextWeek", "thisMonth", "lastMonth",
                          "nextMonth", "thisYear", "lastYear", "last7Days", "last30Days", "last90Days", "allTime", "custom"]

    static func preset(_ name: String, from: String = "", to: String = "", now: Date) -> QueryPeriod? {
        let cal = calendar
        switch name {
        case "today": return day(now).relabeled(String(localized: "今天"))
        case "yesterday": return day(cal.date(byAdding: .day, value: -1, to: now)!).relabeled(String(localized: "昨天"))
        case "tomorrow": return day(cal.date(byAdding: .day, value: 1, to: now)!).relabeled(String(localized: "明天"))
        case "thisWeek": return week(containing: now, label: String(localized: "本周"))
        case "lastWeek": return week(containing: cal.date(byAdding: .day, value: -7, to: now)!, label: String(localized: "上周"))
        case "nextWeek": return week(containing: cal.date(byAdding: .day, value: 7, to: now)!, label: String(localized: "下周"))
        case "thisMonth": return month(containing: now, now: now, label: String(localized: "本月"))
        case "lastMonth": return month(containing: cal.date(byAdding: .month, value: -1, to: now)!, now: now, label: String(localized: "上个月"))
        case "nextMonth": return month(containing: cal.date(byAdding: .month, value: 1, to: now)!, now: now, label: String(localized: "下个月"))
        case "thisYear": return year(containing: now, label: String(localized: "今年"))
        case "lastYear": return year(containing: cal.date(byAdding: .year, value: -1, to: now)!, label: String(localized: "去年"))
        case "last7Days": return rolling(days: 7, now: now, label: String(localized: "最近 7 天"))
        case "last30Days": return rolling(days: 30, now: now, label: String(localized: "最近 30 天"))
        case "last90Days": return rolling(days: 90, now: now, label: String(localized: "最近 3 个月"))
        case "allTime": return allTime(now: now)
        case "custom":
            guard let start = DraftParsing.date(from), let last = DraftParsing.date(to.isEmpty ? from : to), last >= start else { return nil }
            let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: last))!
            let label = from == to || to.isEmpty
                ? start.formatted(.dateTime.month().day())
                : "\(start.formatted(.dateTime.month().day()))–\(last.formatted(.dateTime.month().day()))"
            return QueryPeriod(start: cal.startOfDay(for: start), end: end, unit: .rolling, label: label)
        default: return nil
        }
    }

    /// The first time phrase in `text` (numbers already in digits), and the words it matched.
    static func resolve(_ text: String, now: Date) -> (period: QueryPeriod, matched: String)? {
        let cal = calendar
        let thisYear = cal.component(.year, from: now)
        let thisMonth = cal.component(.month, from: now)
        func monthOf(year: Int, month: Int) -> QueryPeriod? {
            guard (1...12).contains(month), let date = cal.date(from: DateComponents(year: year, month: month, day: 1)) else { return nil }
            return self.month(containing: date, now: now)
        }
        func shifted(_ component: Calendar.Component, _ value: Int) -> Date { cal.date(byAdding: component, value: value, to: now)! }

        if let m = text.firstMatch(of: #/(\d{4})年(\d{1,2})月份?/#), let p = monthOf(year: Int(m.1)!, month: Int(m.2)!) {
            return (p, String(m.0))
        }
        if let m = text.firstMatch(of: #/(去年|今年)(\d{1,2})月份?/#),
           let p = monthOf(year: m.1 == "去年" ? thisYear - 1 : thisYear, month: Int(m.2)!) {
            return (p, String(m.0))
        }
        if let m = text.firstMatch(of: #/(\d{1,2})月(\d{1,2})[号日]/#),
           let date = cal.date(from: DateComponents(year: thisYear, month: Int(m.1)!, day: Int(m.2)!)) {
            return (day(date > now ? cal.date(byAdding: .year, value: -1, to: date)! : date), String(m.0))
        }
        let named: [(Regex<Substring>, () -> QueryPeriod)] = [
            (#/上上个?月/#, { month(containing: shifted(.month, -2), now: now) }),
            (#/上个?月/#, { month(containing: shifted(.month, -1), now: now, label: String(localized: "上个月")) }),
            (#/下个?月/#, { month(containing: shifted(.month, 1), now: now, label: String(localized: "下个月")) }),
            (#/(?:这|本|当)个?月/#, { month(containing: now, now: now, label: String(localized: "本月")) }),
            (#/上上个?(?:周|星期|礼拜)/#, { week(containing: shifted(.day, -14)) }),
            (#/上个?(?:周|星期|礼拜)/#, { week(containing: shifted(.day, -7), label: String(localized: "上周")) }),
            (#/下个?(?:周|星期|礼拜)/#, { week(containing: shifted(.day, 7), label: String(localized: "下周")) }),
            (#/(?:这|本)个?(?:周|星期|礼拜)/#, { week(containing: now, label: String(localized: "本周")) }),
            (#/(?:今天|今日)/#, { day(now).relabeled(String(localized: "今天")) }),
            (#/(?:昨天|昨日)/#, { day(shifted(.day, -1)).relabeled(String(localized: "昨天")) }),
            (#/前天/#, { day(shifted(.day, -2)).relabeled(String(localized: "前天")) }),
            (#/明天/#, { day(shifted(.day, 1)).relabeled(String(localized: "明天")) }),
            (#/后天/#, { day(shifted(.day, 2)).relabeled(String(localized: "后天")) }),
            (#/(?:今年|本年)/#, { year(containing: now, label: String(localized: "今年")) }),
            (#/去年/#, { year(containing: shifted(.year, -1), label: String(localized: "去年")) }),
            (#/前年/#, { year(containing: shifted(.year, -2), label: String(localized: "前年")) }),
        ]
        // 上半年 / 下半年 of this year.
        if let m = text.firstMatch(of: #/(上|下)半年/#) {
            let startMonth = m.1 == "上" ? 1 : 7
            let start = cal.date(from: DateComponents(year: thisYear, month: startMonth, day: 1))!
            let end = cal.date(byAdding: .month, value: 6, to: start)!
            return (QueryPeriod(start: start, end: end, unit: .halfYear, label: String(m.0)), String(m.0))
        }
        // 最近 7 天, 近 3 个月, 过去 2 周, 最近半年.
        if let m = text.firstMatch(of: #/(?:最近|近|过去|这)(\d+|半)个?(天|日|周|星期|礼拜|月|年)/#) {
            let count = m.1 == "半" ? 0 : Int(m.1)!
            let label = String(localized: "最近 \(m.1 == "半" ? "半" : String(count)) \(m.2 == "日" ? "天" : String(m.2))")
            switch m.2 {
            case "天", "日": return (rolling(days: count, now: now, label: label), String(m.0))
            case "周", "星期", "礼拜": return (rolling(days: count * 7, now: now, label: label), String(m.0))
            case "月":
                let months = m.1 == "半" ? 1 : count
                let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
                let start = cal.date(byAdding: .month, value: -months, to: end)!
                let monthLabel = m.1 == "半" ? String(localized: "最近半个月") : label
                let period = m.1 == "半" ? rolling(days: 15, now: now, label: monthLabel)
                                          : QueryPeriod(start: start, end: end, unit: .rolling, label: label)
                return (period, String(m.0))
            default:
                let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
                let start = m.1 == "半" ? cal.date(byAdding: .month, value: -6, to: end)! : cal.date(byAdding: .year, value: -count, to: end)!
                return (QueryPeriod(start: start, end: end, unit: .rolling, label: label), String(m.0))
            }
        }
        for (pattern, make) in named {
            if let m = text.firstMatch(of: pattern) { return (make(), String(m.0)) }
        }
        // 10月 / 10月份: this year, or last year if it hasn't come yet.
        if let m = text.firstMatch(of: #/(\d{1,2})月份?/#), let month = Int(m.1), (1...12).contains(month) {
            return (monthOf(year: month > thisMonth ? thisYear - 1 : thisYear, month: month)!, String(m.0))
        }
        if let m = text.firstMatch(of: #/(1共|总共|全部|所有|累计|有史以来|到现在|至今)/#) {
            return (allTime(now: now), String(m.0))
        }
        return nil
    }
}

extension QueryPeriod {
    nonisolated func relabeled(_ label: String) -> QueryPeriod {
        var copy = self
        copy.label = label
        return copy
    }
}

// MARK: - Query plans

/// What a question asks for, worked out by rules or by AI; the numbers always come from the
/// records on the phone.
nonisolated struct QueryPlan: Codable, Equatable {
    enum Subject: String, Codable, CaseIterable { case expense, income, balance, tasks, bills, expiries, notes }
    enum Measure: String, Codable, CaseIterable { case total, count, average, top, biggest, list, compare }
    enum TaskState: String, Codable, CaseIterable { case open, done, overdue }

    var subject: Subject
    var measure: Measure = .total
    var period: QueryPeriod?
    /// Category names as the person has them.
    var categories: [String] = []
    /// Words to look for in a record's note (咖啡, 滴滴) or in notes (装修, 血脂).
    var keywords: [String] = []
    var taskState: TaskState = .open
}

/// A category as the parser needs it.
nonisolated struct CategoryInfo: Equatable {
    var name: String
    var isIncome: Bool
    var parent: String?
    var seedKey: String?
}

/// Reads common questions without AI: 「这个月吃饭花了多少」「上个月花最多的是哪类」「这周还有哪些待办」.
/// `confident` is false when words are left over that the rules don't understand; AI takes those.
nonisolated enum QuestionParser {
    struct Result {
        var plan: QueryPlan?
        var confident: Bool
    }

    /// Everyday words for the built-in categories.
    static let categoryWords: [(String, [String])] = [
        ("food", ["餐饮", "吃饭", "吃喝", "吃的", "伙食", "饭钱", "吃东西"]),
        ("transport", ["交通", "出行", "通勤", "坐车"]),
        ("shopping", ["购物", "买东西", "网购"]),
        ("housing", ["居住", "住房"]),
        ("fun", ["娱乐", "玩乐"]),
        ("health", ["医疗", "看病", "医药", "买药"]),
        ("learning", ["学习", "教育", "培训"]),
        ("telecom", ["通讯", "手机费"]),
        ("social", ["人情", "送礼", "随礼", "份子钱"]),
        ("travel", ["旅行", "旅游"]),
        ("salary", ["工资", "薪水", "薪资"]),
        ("bonus", ["奖金", "年终奖"]),
        ("investment", ["理财", "利息", "投资收益"]),
    ]

    private static let subjects: [(QueryPlan.Subject, [String])] = [
        (.bills, ["账单", "还款", "要还", "要交", "该交", "该还", "缴费", "信用卡"]),
        // Before expiries: 「过期没做的待办」 is about to-dos.
        (.tasks, ["待办", "要做", "任务", "做完", "没做", "该做", "要办", "事情", "完成了", "完成", "件事"]),
        (.expiries, ["到期", "过期", "续期", "有效期", "证件"]),
        (.balance, ["结余", "存了", "攒了", "收支", "净收入", "剩下多少钱"]),
        (.income, ["收入", "赚了", "赚", "进账", "入账"]),
        (.expense, ["花了", "花", "支出", "消费", "开销", "花销", "用了多少钱", "买", "费"]),
        (.notes, ["笔记", "记过", "提到", "说过"]),
    ]

    private static let measures: [(QueryPlan.Measure, [String])] = [
        (.biggest, ["最贵", "最大的1笔", "最大1笔", "单笔最", "最多的1笔"]),
        (.compare, ["相比", "对比", "比", "多了还是少了", "增加", "减少", "变化"]),
        (.top, ["最多", "哪类", "哪1类", "哪些方面", "哪方面", "主要", "花在哪", "大头", "排名", "分布", "构成"]),
        (.count, ["几笔", "多少笔", "几次", "多少次", "几件", "多少件", "几个", "多少个"]),
        (.average, ["平均", "日均", "每天"]),
        (.list, ["哪些", "明细", "列出", "有什么", "清单", "都有", "列表"]),
    ]

    private static let filler = ["我们", "我的", "我", "1共", "总共", "1下", "看看", "看下", "告诉", "帮我", "查查", "查1下", "查", "多少钱",
                                 "多少", "了", "的", "吗", "呢", "吧", "啊", "呀", "嘛", "么", "还有", "还", "是", "都", "有", "在", "里",
                                 "上", "个", "这", "那", "些", "钱", "块", "元", "和", "跟", "与", "给", "共", "几", "最", "啥", "什么",
                                 "怎么样", "情况", "1些", "1点", "要", "完成", "做", "下", "笔", "事"]

    static func parse(_ question: String, categories: [CategoryInfo], now: Date) -> Result {
        var text = SpokenDate.normalizedNumbers(FillerCleaner.clean(question))
            .replacingOccurrences(of: #"[\s，,。.！!？?、~～]"#, with: "", options: .regularExpression)
        var plan = QueryPlan(subject: .expense)
        var subjectFound = false

        if let (period, matched) = PeriodResolver.resolve(text, now: now) {
            plan.period = period
            text = text.replacingOccurrences(of: matched, with: "")
        }

        // Categories: the person's own names first, longest first, then everyday words.
        var matchedCategory: CategoryInfo?
        for category in categories.sorted(by: { $0.name.count > $1.name.count }) where category.name.count >= 2 && text.contains(category.name) {
            matchedCategory = category
            text = text.replacingOccurrences(of: category.name, with: "")
            break
        }
        if matchedCategory == nil {
            outer: for (key, words) in categoryWords {
                for word in words.sorted(by: { $0.count > $1.count }) where text.contains(word) {
                    matchedCategory = categories.first { $0.seedKey == key }
                    text = text.replacingOccurrences(of: word, with: "")
                    if matchedCategory != nil { break outer }
                }
            }
        }
        // A merchant or item (咖啡, 打车, 房租): search notes, falling back to its category.
        if matchedCategory == nil {
            for (key, words) in LedgerCSV.categoryKeywords {
                if let word = words.filter({ $0.count >= 2 }).sorted(by: { $0.count > $1.count }).first(where: { text.contains($0) }) {
                    plan.keywords = [word]
                    text = text.replacingOccurrences(of: word, with: "")
                    if let category = categories.first(where: { $0.seedKey == key }) { plan.categories = [category.name] }
                    subjectFound = true
                    break
                }
            }
        }
        if let matchedCategory {
            plan.categories = [matchedCategory.name]
            if matchedCategory.isIncome { plan.subject = .income }
            subjectFound = true
        }

        for (subject, words) in subjects {
            if let word = words.sorted(by: { $0.count > $1.count }).first(where: { text.contains($0) }) {
                // A category or merchant already decided it's money (工资 → income); "花" doesn't change that.
                let keepsCurrent = subjectFound && (subject == .expense || subject == .notes)
                if !keepsCurrent { plan.subject = subject }
                subjectFound = true
                text = text.replacingOccurrences(of: word, with: "")
                break
            }
        }
        for (measure, words) in measures {
            if let word = words.sorted(by: { $0.count > $1.count }).first(where: { text.contains($0) }) {
                plan.measure = measure
                text = text.replacingOccurrences(of: word, with: "")
                break
            }
        }
        // 「最贵的一笔」「花在哪」 are about spending even without 花 or 钱.
        if !subjectFound, [.biggest, .top, .average, .compare].contains(plan.measure) || text.contains("笔") {
            subjectFound = true
        }
        // "上周比上上周": a second period word is part of the comparison.
        if plan.measure == .compare, let (_, matched) = PeriodResolver.resolve(text, now: now) {
            text = text.replacingOccurrences(of: matched, with: "")
        }

        switch plan.subject {
        case .tasks:
            if ["完成", "做完", "做了"].contains(where: question.contains) { plan.taskState = .done }
            else if ["过期", "逾期", "没做", "拖"].contains(where: question.contains) { plan.taskState = .overdue }
            if plan.measure == .total { plan.measure = plan.taskState == .done ? .count : .list }
        case .bills, .expiries, .notes:
            if plan.measure == .total || plan.measure == .top { plan.measure = .list }
        default:
            break
        }

        for word in filler.sorted(by: { $0.count > $1.count }) {
            text = text.replacingOccurrences(of: word, with: "")
        }
        guard subjectFound else {
            // Nothing recognisable: whatever is left might be found in notes.
            let left = text.trimmingCharacters(in: .whitespaces)
            return Result(plan: left.isEmpty ? nil : QueryPlan(subject: .notes, measure: .list, period: plan.period, keywords: [left]),
                          confident: false)
        }
        if !text.isEmpty, plan.keywords.isEmpty, text.count >= 2 { plan.keywords = [text] }
        return Result(plan: plan, confident: text.count <= 1)
    }

    /// Whether typed or spoken text is a question rather than something to record.
    static func looksLikeQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return false }
        if trimmed.hasSuffix("？") || trimmed.hasSuffix("?") { return true }
        return ["多少", "哪些", "哪类", "几笔", "几件", "有什么", "有没有", "是不是", "什么时候", "花在哪", "吗"]
            .contains(where: trimmed.contains)
    }
}

// MARK: - Answers

/// What the person sees: one sentence, a few supporting lines, and the records behind them.
nonisolated struct AskAnswer: Equatable, Codable {
    enum Source: Equatable, Codable {
        /// Worked out on the phone without AI.
        case rules
        case ai(CaptureSource)
    }

    struct Bar: Equatable, Identifiable, Codable {
        var id: String { label }
        var label: String
        var amount: Decimal
        var fraction: Double
        var colorHex: String
        /// "+¥120" against the previous period, when known.
        var change: String?
    }

    struct Item: Equatable, Identifiable, Codable {
        enum Link: Equatable, Codable { case task(String), bill(String), expiry(String), note(String) }
        var id: String
        var title: String
        var subtitle: String
        var trailing: String = ""
        var link: Link?
    }

    var headline: String
    var details: [String] = []
    var bars: [Bar] = []
    var items: [Item] = []
    var source: Source = .rules
    var plan: QueryPlan?
}

/// Works out the answer to a plan from the records. Nothing leaves the phone here.
enum QueryRunner {
    static func run(_ plan: QueryPlan, context: ModelContext, now: Date = .now) -> AskAnswer {
        switch plan.subject {
        case .expense, .income: money(plan, context: context, now: now)
        case .balance: balance(plan, context: context, now: now)
        case .tasks: tasks(plan, context: context, now: now)
        case .bills: bills(plan, context: context, now: now)
        case .expiries: expiries(plan, context: context, now: now)
        case .notes: noteMatches(plan, context: context)
        }
    }

    private static var currency: String { LedgerSummary.baseCurrency }

    private static func money(_ value: Decimal) -> String { value.money(currency) }

    /// Entries of one kind in the period, narrowed to the plan's categories and keywords.
    static func entries(_ plan: QueryPlan, kind: EntryKind, period: QueryPeriod, context: ModelContext) -> [LedgerEntry] {
        let start = period.start, end = period.end, raw = kind.rawValue
        let all = (try? context.fetch(FetchDescriptor<LedgerEntry>(
            predicate: #Predicate { $0.date >= start && $0.date < end && $0.kindRaw == raw },
            sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        let categories = Set(plan.categories)
        let inCategory = { (entry: LedgerEntry) -> Bool in
            guard !categories.isEmpty else { return true }
            return categories.contains(entry.category?.name ?? "") || categories.contains(entry.category?.parent?.name ?? "")
        }
        guard !plan.keywords.isEmpty else { return all.filter(inCategory) }
        let byKeyword = all.filter { entry in
            plan.keywords.contains { entry.note.localizedCaseInsensitiveContains($0) || (entry.category?.name.contains($0) ?? false) }
        }
        // "打车" matched no note: fall back to the category it belongs to.
        return byKeyword.isEmpty ? all.filter(inCategory) : byKeyword
    }

    private static func subjectWord(_ plan: QueryPlan, kind: EntryKind) -> String {
        let what = plan.keywords.first ?? plan.categories.first ?? ""
        let noun = kind == .income ? String(localized: "收入") : String(localized: "支出")
        if what.isEmpty { return noun }
        return kind == .income ? String(localized: "\(what)收入") : String(localized: "「\(what)」支出")
    }

    private static func money(_ plan: QueryPlan, context: ModelContext, now: Date) -> AskAnswer {
        let kind: EntryKind = plan.subject == .income ? .income : .expense
        let period = plan.period ?? PeriodResolver.month(containing: now, now: now, label: String(localized: "本月"))
        let list = entries(plan, kind: kind, period: period, context: context)
        let total = list.reduce(Decimal(0)) { $0 + $1.baseAmount }
        let what = subjectWord(plan, kind: kind)
        var answer = AskAnswer(headline: "", plan: plan)

        guard !list.isEmpty else {
            answer.headline = String(localized: "\(period.label)没有\(what)记录。")
            return answer
        }

        let previous = PeriodResolver.previous(period, now: now).map { PeriodResolver.samePoint(in: $0, for: period, now: now) }
        let previousTotal = previous.map { entries(plan, kind: kind, period: $0, context: context).reduce(Decimal(0)) { $0 + $1.baseAmount } }
        let comparison = previous.flatMap { previous in
            previousTotal.flatMap { changeSentence(total, against: $0, label: previousLabel(period, previous: previous, now: now)) }
        }
        let days = max(1, PeriodResolver.calendar.dateComponents([.day], from: period.start, to: min(period.end, nextMidnight(now))).day ?? 1)

        switch plan.measure {
        case .count:
            answer.headline = String(localized: "\(period.label)\(what)共 \(list.count) 笔，\(money(total))。")
        case .average:
            answer.headline = String(localized: "\(period.label)\(what)日均 \(money(total / Decimal(days)))。")
            answer.details.append(String(localized: "共 \(money(total))，\(days) 天，\(list.count) 笔"))
        case .top:
            let bars = breakdown(list, plan: plan, previous: previous.map { entries(plan, kind: kind, period: $0, context: context) } ?? [])
            if let first = bars.first {
                let share = first.fraction.formatted(.percent.precision(.fractionLength(0)))
                answer.headline = kind == .income
                    ? String(localized: "\(period.label)收入最多的是\(first.label) \(money(first.amount))，占 \(share)。")
                    : String(localized: "\(period.label)花得最多的是\(first.label) \(money(first.amount))，占 \(share)。")
            }
            answer.bars = bars
            answer.details.append(String(localized: "\(what)合计 \(money(total))"))
        case .biggest:
            let top = list.sorted { $0.baseAmount > $1.baseAmount }.prefix(5)
            if let first = top.first {
                answer.headline = String(localized: "\(period.label)最大的一笔是「\(first.displayTitle)」\(money(first.baseAmount))（\(first.date.formatted(.dateTime.month().day()))）。")
            }
            answer.items = top.map(item)
        case .list:
            answer.headline = String(localized: "\(period.label)\(what)共 \(list.count) 笔，\(money(total))。")
            answer.items = list.prefix(20).map(item)
        case .compare, .total:
            answer.headline = String(localized: "\(period.label)\(what) \(money(total))，共 \(list.count) 笔。")
            if plan.measure == .compare, let comparison {
                answer.headline = String(localized: "\(period.label)\(what) \(money(total))，\(comparison)。")
            } else if let comparison {
                answer.details.append(comparison)
            }
            if period.unit != .day { answer.details.append(String(localized: "日均 \(money(total / Decimal(days)))")) }
            // The overall budget, for this month's spending.
            if kind == .expense, period.unit == .month, period.holds(now),
               let budget = LedgerSummary.monthlyBudget(categoryName: plan.categories.first, context: context), budget > 0,
               plan.keywords.isEmpty {
                let left = budget - total
                answer.details.append(left >= 0 ? String(localized: "预算还剩 \(money(left))") : String(localized: "已超出预算 \(money(-left))"))
            }
            if plan.categories.isEmpty, plan.keywords.isEmpty {
                answer.bars = Array(breakdown(list, plan: plan, previous: []).prefix(5))
            } else {
                answer.items = list.prefix(8).map(item)
            }
        }
        return answer
    }

    private static func balance(_ plan: QueryPlan, context: ModelContext, now: Date) -> AskAnswer {
        let period = plan.period ?? PeriodResolver.month(containing: now, now: now, label: String(localized: "本月"))
        var all = plan
        all.categories = []
        all.keywords = []
        let income = entries(all, kind: .income, period: period, context: context).reduce(Decimal(0)) { $0 + $1.baseAmount }
        let expense = entries(all, kind: .expense, period: period, context: context).reduce(Decimal(0)) { $0 + $1.baseAmount }
        let left = income - expense
        let headline = left >= 0
            ? String(localized: "\(period.label)收入 \(money(income))，支出 \(money(expense))，结余 \(money(left))。")
            : String(localized: "\(period.label)收入 \(money(income))，支出 \(money(expense))，超支 \(money(-left))。")
        return AskAnswer(headline: headline,
                         plan: plan)
    }

    private static func tasks(_ plan: QueryPlan, context: ModelContext, now: Date) -> AskAnswer {
        let calendar = PeriodResolver.calendar
        let endOfToday = nextMidnight(now)
        var answer = AskAnswer(headline: "", plan: plan)
        switch plan.taskState {
        case .done:
            let period = plan.period ?? PeriodResolver.week(containing: now, label: String(localized: "本周"))
            let start = period.start, end = period.end
            let done = (try? context.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.isCompleted && $0.completedAt != nil },
                sortBy: [SortDescriptor(\.completedAt, order: .reverse)]))) ?? []
            let inPeriod = done.filter { ($0.completedAt ?? .distantPast) >= start && ($0.completedAt ?? .distantPast) < end }
            answer.headline = inPeriod.isEmpty
                ? String(localized: "\(period.label)还没有完成的待办。")
                : String(localized: "\(period.label)完成了 \(inPeriod.count) 件待办。")
            answer.items = inPeriod.prefix(20).map { task in
                AskAnswer.Item(id: ModelRef.encode(task.persistentModelID), title: task.title,
                               subtitle: task.completedAt.map { String(localized: "\($0.formatted(.dateTime.month().day())) 完成") } ?? "",
                               link: .task(ModelRef.encode(task.persistentModelID)))
            }
        case .open, .overdue:
            let open = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.isCompleted }))) ?? []
            let period = plan.period
            let chosen: [TaskItem]
            if plan.taskState == .overdue {
                chosen = open.filter { $0.isOverdue(now: now, calendar: calendar) }
            } else if let period {
                // A period's to-dos, plus the overdue ones still waiting.
                chosen = open.filter { task in
                    guard let due = task.dueDate else { return false }
                    return period.holds(due) || (period.end > now && task.isOverdue(now: now, calendar: calendar))
                }
            } else {
                chosen = open.filter { ($0.dueDate ?? .distantFuture) < endOfToday }
            }
            let sorted = chosen.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
            let label = plan.taskState == .overdue ? String(localized: "已过期的") : (period?.label ?? String(localized: "今天"))
            answer.headline = sorted.isEmpty
                ? String(localized: "\(label)没有待办。")
                : sorted.contains { $0.isOverdue(now: now, calendar: calendar) } && plan.taskState != .overdue
                    ? String(localized: "\(label)有 \(sorted.count) 件待办（含已过期的）。")
                    : String(localized: "\(label)有 \(sorted.count) 件待办。")
            answer.items = sorted.prefix(20).map { task in
                AskAnswer.Item(id: ModelRef.encode(task.persistentModelID), title: task.title,
                               subtitle: dueText(task, now: now), link: .task(ModelRef.encode(task.persistentModelID)))
            }
        }
        return answer
    }

    private static func bills(_ plan: QueryPlan, context: ModelContext, now: Date) -> AskAnswer {
        let today = PeriodResolver.calendar.startOfDay(for: now)
        let period = plan.period ?? QueryPeriod(start: today, end: PeriodResolver.calendar.date(byAdding: .day, value: 30, to: today)!,
                                                unit: .rolling, label: String(localized: "接下来 30 天"))
        let all = (try? context.fetch(FetchDescriptor<Bill>(predicate: #Predicate { $0.isActive }, sortBy: [SortDescriptor(\.nextDueDate)]))) ?? []
        let due = all.filter { period.holds($0.nextDueDate) || ($0.nextDueDate < today && period.end > now) }
            .filter { plan.keywords.isEmpty || plan.keywords.contains(where: $0.name.contains) }
        let total = due.reduce(Decimal(0)) { $0 + $1.amount }
        var answer = AskAnswer(headline: due.isEmpty ? String(localized: "\(period.label)没有要付的账单。")
                                                     : String(localized: "\(period.label)有 \(due.count) 笔账单，共约 \(money(total))。"),
                               plan: plan)
        answer.items = due.map { bill in
            AskAnswer.Item(id: ModelRef.encode(bill.persistentModelID), title: bill.name,
                           subtitle: "\(bill.nextDueDate.formatted(.dateTime.month().day())) · \(DayText.countdown(to: bill.nextDueDate, now: now))",
                           trailing: bill.amount.money(bill.currencyCode), link: .bill(ModelRef.encode(bill.persistentModelID)))
        }
        return answer
    }

    private static func expiries(_ plan: QueryPlan, context: ModelContext, now: Date) -> AskAnswer {
        let today = PeriodResolver.calendar.startOfDay(for: now)
        let period = plan.period ?? QueryPeriod(start: today, end: PeriodResolver.calendar.date(byAdding: .day, value: 90, to: today)!,
                                                unit: .rolling, label: String(localized: "接下来 3 个月"))
        let all = (try? context.fetch(FetchDescriptor<ExpiryItem>(predicate: #Predicate { !$0.isArchived },
                                                                   sortBy: [SortDescriptor(\.expiryDate)]))) ?? []
        let expired = all.filter { $0.expiryDate < today }
        let soon = all.filter { period.holds($0.expiryDate) && $0.expiryDate >= today }
            .filter { plan.keywords.isEmpty || plan.keywords.contains(where: $0.name.contains) }
        var headline = soon.isEmpty ? String(localized: "\(period.label)没有要到期的。") : String(localized: "\(period.label)有 \(soon.count) 样要到期。")
        if !expired.isEmpty { headline += String(localized: "另有 \(expired.count) 样已经过期。") }
        var answer = AskAnswer(headline: headline, plan: plan)
        answer.items = (expired + soon).map { item in
            AskAnswer.Item(id: ModelRef.encode(item.persistentModelID), title: item.name,
                           subtitle: "\(item.expiryText) · \(DayText.countdown(to: item.expiryDate, now: now))",
                           link: .expiry(ModelRef.encode(item.persistentModelID)))
        }
        return answer
    }

    /// Note entries mentioning the keywords, best match first; what AI answers from.
    static func matchingEntries(_ keywords: [String], context: ModelContext, limit: Int = 6) -> [NoteEntry] {
        let words = keywords.flatMap(searchTerms).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let entries = (try? context.fetch(FetchDescriptor<NoteEntry>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        let scored = entries.compactMap { entry -> (NoteEntry, Int)? in
            let haystack = (entry.note?.title ?? "") + " " + entry.text
            let score = words.reduce(0) { $0 + (haystack.localizedCaseInsensitiveContains($1) ? $1.count : 0) }
            return score > 0 ? (entry, score) : nil
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.date > $1.0.date }.prefix(limit).map(\.0)
    }

    /// A long phrase also searched as its two-character pieces: 「装修下1步」 → 装修, 修下, 下1, 1步.
    private static func searchTerms(_ keyword: String) -> [String] {
        let characters = Array(keyword)
        guard characters.count > 3 else { return [keyword] }
        return [keyword] + (0..<(characters.count - 1)).map { String(characters[$0...$0 + 1]) }
    }

    private static func noteMatches(_ plan: QueryPlan, context: ModelContext) -> AskAnswer {
        let found = matchingEntries(plan.keywords, context: context)
        var answer = AskAnswer(headline: found.isEmpty ? String(localized: "笔记里没找到相关的内容。")
                                                       : String(localized: "笔记里找到 \(found.count) 条相关记录。"),
                               plan: plan)
        answer.items = found.map(noteItem)
        return answer
    }

    static func noteItem(_ entry: NoteEntry) -> AskAnswer.Item {
        let snippet = entry.text.count > 80 ? String(entry.text.prefix(80)) + "…" : entry.text
        return AskAnswer.Item(id: ModelRef.encode(entry.persistentModelID),
                              title: snippet,
                              subtitle: "\(entry.note?.displayTitle ?? String(localized: "笔记")) · \(entry.date.formatted(.dateTime.year().month().day()))",
                              link: entry.note.map { .note(ModelRef.encode($0.persistentModelID)) })
    }

    // MARK: Helpers

    private static func item(_ entry: LedgerEntry) -> AskAnswer.Item {
        AskAnswer.Item(id: ModelRef.encode(entry.persistentModelID), title: entry.displayTitle,
                       subtitle: [entry.date.formatted(.dateTime.month().day()), entry.category?.name ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                       trailing: entry.baseAmount.money(currency))
    }

    /// Totals by top-level category, or by subcategory when one category is asked about.
    static func breakdown(_ entries: [LedgerEntry], plan: QueryPlan, previous: [LedgerEntry]) -> [AskAnswer.Bar] {
        func group(_ entry: LedgerEntry) -> LedgerCategory? {
            if plan.categories.count == 1, entry.category?.parent?.name == plan.categories[0] { return entry.category }
            return entry.category?.parent ?? entry.category
        }
        var totals: [String: (Decimal, String)] = [:]
        for entry in entries {
            let category = group(entry)
            let name = category?.name ?? String(localized: "未分类")
            totals[name, default: (0, category?.colorHex ?? "#8E8E93")].0 += entry.baseAmount
        }
        var before: [String: Decimal] = [:]
        for entry in previous { before[group(entry)?.name ?? String(localized: "未分类"), default: 0] += entry.baseAmount }
        let sum = totals.values.reduce(Decimal(0)) { $0 + $1.0 }
        return totals.sorted { $0.value.0 > $1.value.0 }.map { name, value in
            let change: String? = previous.isEmpty ? nil : {
                let diff = value.0 - (before[name] ?? 0)
                return diff == 0 ? nil : (diff > 0 ? "+" : "-") + abs(diff).money(currency)
            }()
            return AskAnswer.Bar(label: name, amount: value.0,
                                 fraction: sum > 0 ? NSDecimalNumber(decimal: value.0 / sum).doubleValue : 0,
                                 colorHex: value.1, change: change)
        }
    }

    /// "比上个月多 ¥120（+15%）"
    static func changeSentence(_ value: Decimal, against previous: Decimal, label: String) -> String? {
        guard previous > 0 else { return nil }
        let diff = value - previous
        let percent = NSDecimalNumber(decimal: diff / previous).doubleValue
        if abs(percent) < 0.005 { return String(localized: "和\(label)差不多") }
        let amount = abs(diff).money(LedgerSummary.baseCurrency)
        let pct = abs(percent).formatted(.percent.precision(.fractionLength(0)))
        return diff > 0 ? String(localized: "比\(label)多 \(amount)（+\(pct)）") : String(localized: "比\(label)少 \(amount)（-\(pct)）")
    }

    static func previousLabel(_ period: QueryPeriod, previous: QueryPeriod, now: Date) -> String {
        let partial = period.holds(now) && [.week, .month, .year].contains(period.unit) ? String(localized: "同期") : ""
        switch period.unit {
        case .day: return String(localized: "前一天")
        case .week: return (period.label == String(localized: "本周") ? String(localized: "上周") : String(localized: "前一周")) + partial
        case .month: return (period.label == String(localized: "本月") ? String(localized: "上个月") : previous.label.replacingOccurrences(of: partial, with: "")) + partial
        case .year: return previous.label.replacingOccurrences(of: partial, with: "") + partial
        default: return String(localized: "之前同样长的时间")
        }
    }

    private static func nextMidnight(_ now: Date) -> Date {
        PeriodResolver.calendar.date(byAdding: .day, value: 1, to: PeriodResolver.calendar.startOfDay(for: now))!
    }

    private static func dueText(_ task: TaskItem, now: Date) -> String {
        guard let due = task.dueDate else { return "" }
        let day = DayText.countdown(to: due, now: now)
        let time = task.hasDueTime ? " " + due.formatted(date: .omitted, time: .shortened) : ""
        return task.isOverdue(now: now) ? String(localized: "已过期 · \(due.formatted(.dateTime.month().day()))") : day + time
    }
}
