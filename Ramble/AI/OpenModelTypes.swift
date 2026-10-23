import Foundation
import FoundationModels

/// Lean output for open models on the phone. They write every field, keys included, at about
/// 15–20 tokens a second, so each field costs time: these keep only what the model must
/// decide and leave dates, repeats and kinds to code. Field order is the order the model writes.
@Generable
nonisolated struct OpenCapture {
    @Guide(description: "Every record mentioned, in the order mentioned.")
    var items: [OpenCaptureItem]
}

@Generable
nonisolated struct OpenCaptureItem {
    @Guide(description: "expense: money already spent. income: money received. bill: a payment due later (信用卡还款, 房租, 话费, 会员续费). task: something to do. expiry: something that expires (证件, 保险, 合同, 保修). note: progress on an ongoing matter.",
           .anyOf(CaptureSchema.localItemTypes))
    var type: String
    @Guide(description: "A short name of 2 to 6 characters, e.g. 午餐, 信用卡还款, 护照, 铺砖. No amounts or dates.")
    var title: String
    @Guide(description: "The amount as a plain number such as 35 or 2180, or empty.")
    var amount: String
    @Guide(description: "The time words exactly as said, e.g. 今天, 十五号, 下周三, 明年三月. Empty if none.")
    var when: String
    @Guide(description: "For money: the closest category from the provided list. Empty otherwise.")
    var category: String
}

@Generable
nonisolated struct OpenOrganizedNote {
    @Guide(description: "The passage written as clear sentences with punctuation: filler, repeats and false starts removed. Every fact kept.")
    var cleanedText: String
    @Guide(description: "One per sentence that asks for something to be done at a time or by a deadline, e.g. 下周三可以铺砖, 三个月后复查. Empty only if there is none.")
    var reminders: [OpenReminder]
}

/// Just the tidied text: open models write it best when that's all they're asked for.
@Generable
nonisolated struct OpenTidiedText {
    @Guide(description: "整理后的文字：通顺的中文书面语，有标点，事实一个不少。")
    var cleanedText: String
}

/// The same for English dictation, so the Chinese wording above (tuned on real dictation) stays as it is.
@Generable
nonisolated struct OpenTidiedEnglishText {
    @Guide(description: "The tidied text: clear written English with punctuation, every fact kept.")
    var cleanedText: String
}

@Generable
nonisolated struct OpenReminder {
    @Guide(description: "That sentence, exactly as in cleanedText.")
    var quote: String
    @Guide(description: "The action in a few words, e.g. 铺砖, 复查血脂.")
    var title: String
    @Guide(description: "The time words exactly as said, e.g. 下周三, 三个月以后, 下周四下午三点.")
    var when: String
}

extension OpenCapture {
    /// Worked examples for the instructions: small models follow a pattern far better than rules.
    static let examples = """

    Example
    Input: 嗯昨天打车花了二十八，那个房租月底要交三千五，孩子老师说下周一开家长会，驾照明年六月到期
    Output: {"items": [{"type": "expense", "title": "打车", "amount": "28", "when": "昨天", "category": "交通"}, {"type": "bill", "title": "房租", "amount": "3500", "when": "月底", "category": "居住"}, {"type": "note", "title": "孩子", "amount": "", "when": "", "category": ""}, {"type": "task", "title": "家长会", "amount": "", "when": "下周一", "category": ""}, {"type": "expiry", "title": "驾照", "amount": "", "when": "明年六月", "category": ""}]}
    """

    /// The full records. What the model wasn't asked is worked out from what was said: dates
    /// from the time words, a note's text and a task's sentence from the input, kinds from names.
    func parsed(input: String, now: Date) -> ParsedCapture {
        let spoken = NoteCommands.withoutCaptureCommand(FillerCleaner.clean(input))
        let clauses = Self.clauses(of: spoken)
        let hasNote = items.contains { $0.type == "note" }
        // One note per capture: every note item gets the whole passage, so later ones only repeat it.
        let firstNote = items.firstIndex { $0.type == "note" }
        let kept = items.enumerated().filter { $0.element.type != "note" || $0.offset == firstNote }.map(\.element)
        let endOfToday = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now
        var parsed = kept.map { raw -> ParsedItem in
            var item = ParsedItem()
            item.type = CaptureSchema.itemTypes.contains(raw.type) ? raw.type : "task"
            item.title = Self.cleanTitle(raw.title)
            item.amount = raw.amount
            item.category = raw.category
            if item.type == "note" {
                // Notes have no category; a small model sometimes puts the note's name there.
                if !raw.category.trimmed.isEmpty, !Self.isPlaceholder(raw.category) { item.title = Self.cleanTitle(raw.category) }
                item.category = ""
            }
            let when = raw.when.trimmed
            let named = clauses.first { !item.title.isEmpty && $0.contains(item.title) }
                ?? clauses.first { clause in !raw.amount.isEmpty && ChineseNumerals.normalize(clause).contains(raw.amount) }
            let timed = clauses.first { !when.isEmpty && $0.contains(when) }
            let isMoney = ["expense", "income", "bill"].contains(item.type)
            // Money belongs to the clause that names it: 「明天复查，挂号费花了五十」's time isn't the fee's.
            let clause = isMoney ? (named ?? timed) : (timed ?? named)
            if let clause, item.type == "expense" || item.type == "bill" {
                item.type = Self.moneyType(item.type, clause: clause)
            }
            // Owed, not yet moved: 「张三还欠我两千」. May be dated ahead, unlike money already spent.
            if let clause, item.type == "expense" || item.type == "income", let direction = OutstandingCues.direction(in: clause) {
                item.type = direction.rawValue
                item.counterparty = OutstandingCues.counterparty(in: clause, direction: direction)
                item.quote = clause
            }
            let timeWords: [String]
            if isMoney {
                // Only the time words said with this item count.
                let own = clause ?? ""
                timeWords = !when.isEmpty && own.contains(when) ? [when, own] : [own]
            } else {
                timeWords = [when, clause ?? "", item.title]
            }
            if let date = timeWords.lazy.compactMap({ SpokenDate.resolve($0, now: now) }).first,
               // Money already spent or received isn't dated ahead.
               !(["expense", "income"].contains(item.type) && date.date >= endOfToday) {
                item.apply(date)
            }
            if Self.isPlaceholder(item.title) || (!item.counterparty.isEmpty && item.title == item.counterparty) {
                switch item.type {
                case "note": item.title = Self.noteTitle(from: spoken)
                case "receivable", "payable": item.title = String(localized: "欠款")
                default: item.title = clause.flatMap(ReminderFinder.title) ?? Self.noteTitle(from: clause ?? spoken)
                }
            }
            switch item.type {
            case "note":
                item.note = spoken
            case "task" where hasNote:
                // Tie the reminder to its sentence in the note, as a cloud model would.
                if let clause { item.quote = clause }
            case "bill":
                item.billKind = Self.billKind(for: item.title)
                if let day = DraftParsing.date(item.date) {
                    item.repeatFrequency = "monthly"
                    item.repeatMonthDay = Calendar.current.component(.day, from: day)
                }
                item.reminderDaysBefore = [3, 0]
            case "expiry":
                item.expiryKind = Self.expiryKind(for: item.title)
                item.reminderDaysBefore = item.expiryKind == ExpiryKind.document.rawValue ? [90, 30, 7] : [30, 7, 0]
            default:
                break
            }
            return item
        }
        // A step for a later day inside the note that the model didn't make a to-do.
        if hasNote {
            for suggestion in ReminderFinder.find(in: clauses.joined(separator: "，"), now: now)
            where !parsed.contains(where: { $0.type == "task" && ($0.date == suggestion.date || $0.quote == suggestion.quote) }) {
                var task = ParsedItem()
                task.type = "task"
                task.title = suggestion.title
                task.date = suggestion.date
                task.time = suggestion.time
                task.quote = suggestion.quote
                parsed.append(task)
            }
        }
        Self.mergeSplitTotals(&parsed, spoken: spoken)
        Self.addOwedMoney(&parsed, clauses: clauses, now: now)
        return ParsedCapture(items: parsed)
    }

    /// 「铺暖气和买瓷砖一共花了八万二」: one total said once, which a small model can put on each
    /// thing it paid for. Records sharing an amount that was said fewer times become one.
    static func mergeSplitTotals(_ items: inout [ParsedItem], spoken: String) {
        let said = amounts(in: spoken)
        var index = 0
        while index < items.count {
            let first = items[index]
            if ["expense", "income"].contains(first.type), let amount = Decimal(string: first.amount), amount > 0 {
                let sameAmount = items.indices.filter { $0 > index && items[$0].type == first.type && Decimal(string: items[$0].amount) == amount }
                let times = said.filter { $0 == amount }.count
                if !sameAmount.isEmpty, times < sameAmount.count + 1 {
                    var titles = [first.title]
                    for other in sameAmount where !titles.contains(items[other].title) { titles.append(items[other].title) }
                    items[index].title = titles.joined(separator: "和")
                    if items[index].category.isEmpty { items[index].category = sameAmount.map { items[$0].category }.first { !$0.isEmpty } ?? "" }
                    for other in sameAmount.reversed() { items.remove(at: other) }
                }
            }
            index += 1
        }
    }

    /// Owed money a small model filed as a note or a to-do (「张三还欠我两千，还欠师傅三千工钱月底给」)
    /// becomes 应收 or 应付; what the model made of the same words goes.
    static func addOwedMoney(_ items: inout [ParsedItem], clauses: [String], now: Date) {
        var owed: [String] = []
        for clause in clauses {
            guard let direction = OutstandingCues.direction(in: clause), let amount = amounts(in: clause).max() else { continue }
            owed.append(clause)
            if items.contains(where: { ($0.type == "receivable" || $0.type == "payable") && $0.quote == clause }) { continue }
            items.removeAll { other in
                (other.type == "task" && (other.quote == clause || (!other.title.isEmpty && clause.contains(other.title))))
                    || (["expense", "income"].contains(other.type) && Decimal(string: other.amount) == amount)
            }
            var item = ParsedItem()
            item.type = direction.rawValue
            item.title = String(localized: "欠款")
            item.amount = "\(amount)"
            item.counterparty = OutstandingCues.counterparty(in: clause, direction: direction)
            item.quote = clause
            if let date = SpokenDate.resolve(clause, now: now) { item.apply(date) }
            items.append(item)
        }
        guard !owed.isEmpty else { return }
        // A note, or a to-do the note's sentences suggested, that only repeats the owed money.
        items.removeAll { item in
            (item.type == "note" && Self.clauses(of: item.note).allSatisfy(owed.contains))
                || (item.type == "task" && owed.contains(item.quote))
        }
    }

    /// The amounts said, as numbers: 两千 → 2000, 82,000 → 82000. Small numbers (张三's 三) don't count.
    static func amounts(in text: String) -> [Decimal] {
        let plain = text.replacing(#/([0-9]),([0-9]{3})/#) { match in match.1 + match.2 }
        return ChineseNumerals.normalize(plain).matches(of: #/[0-9]+(?:\.[0-9]+)?/#)
            .compactMap { Decimal(string: String($0.output)) }
            .filter { $0 >= 10 }
    }

    /// Clauses as said, split at punctuation and, since dictation often has none, at the words
    /// that start a new thing (然后, 还有, 另外, 顺便).
    static func clauses(of text: String) -> [String] {
        ReminderFinder.clauses(of: text).flatMap { clause in
            clause.split(separator: #/(?:还有就是|再就是|然后|还有|另外|顺便|以及|接着)/#).map { String($0).trimmed }
        }.filter { !$0.isEmpty }
    }

    /// Names a model gives when it has none: its own field names, a type, or nothing in Chinese.
    static func isPlaceholder(_ title: String) -> Bool {
        let name = title.trimmed.lowercased()
        let placeholders: Set<String> = ["note", "notes", "task", "expense", "income", "bill", "expiry", "transfer", "title", "name",
                                         "untitled", "receivable", "payable", "笔记", "新笔记", "待办", "支出", "收入", "账单", "到期", "转账", "应收", "应付", "记录", "内容",
                                         "备忘", "备忘录", "事项", "未命名", "无"]
        return name.count < 2 || placeholders.contains(name) || !name.contains(where: { $0.isLetter && !$0.isASCII })
    }

    /// A short name for a new note from its first clause: 「点中平台短句已经上传好了」→「点中平台短句已经上传」.
    static func noteTitle(from text: String) -> String {
        let first = clauses(of: text).first ?? text
        let cleaned = (ReminderFinder.title(of: first) ?? first).trimmingCharacters(in: CharacterSet(charactersIn: " ，,。了"))
        return String(cleaned.prefix(10))
    }

    /// Small models sometimes pack the amount or date into the name ("信用卡还款 2180 CNY (10-15)").
    static func cleanTitle(_ title: String) -> String {
        var result = FillerCleaner.clean(title)
        for pattern in [#"[（(][^)）]*[)）]"#, #"\d[\d.,]*\s*(?:元|块|CNY|RMB|¥)?"#, #"¥\s*"#] {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return result.trimmed
    }

    /// Small models mix up money spent and money due; the verb says which ("花了三十五", "要还两千").
    static func moneyType(_ type: String, clause: String) -> String {
        let due = ["要还", "要交", "该还", "该交", "得还", "得交", "待还", "到期还"].contains(where: clause.contains)
        let spent = ["花了", "花掉", "买了", "付了", "交了", "还了"].contains(where: clause.contains)
        if spent && !due { return "expense" }
        if due && !spent { return "bill" }
        return type
    }

    static func billKind(for title: String) -> String {
        let kinds: [(BillKind, [String])] = [
            (.creditCard, ["信用卡", "花呗", "白条"]),
            (.rent, ["房租", "租金"]),
            (.utilities, ["水费", "电费", "燃气", "物业", "水电"]),
            (.phone, ["话费", "宽带", "流量"]),
            (.loan, ["房贷", "车贷", "贷款", "还款"]),
            (.subscription, ["会员", "订阅", "续费"]),
            (.insurance, ["保险", "保费"]),
        ]
        return kinds.first { $0.1.contains(where: title.contains) }?.0.rawValue ?? BillKind.other.rawValue
    }

    static func expiryKind(for title: String) -> String {
        let kinds: [(ExpiryKind, [String])] = [
            (.document, ["护照", "身份证", "驾照", "驾驶证", "签证", "通行证", "居住证", "证件"]),
            (.insurance, ["保险", "车险", "保单"]),
            (.contract, ["合同", "租约", "协议"]),
            (.warranty, ["保修", "质保"]),
            (.membership, ["会员", "年卡", "订阅"]),
        ]
        return kinds.first { $0.1.contains(where: title.contains) }?.0.rawValue ?? ExpiryKind.other.rawValue
    }
}

extension OpenOrganizedNote {
    /// Converts to the shared result; the date comes from the time words, or the sentence itself.
    func organized(noteTitle: String) -> OnDeviceOrganizedNote {
        OnDeviceOrganizedNote(cleanedText: cleanedText, title: "", reminders: reminders.map {
            OnDeviceReminderSuggestion(quote: $0.quote, title: $0.title, when: $0.when.trimmed.isEmpty ? $0.quote : $0.when,
                                       date: "", time: "")
        })
    }
}
