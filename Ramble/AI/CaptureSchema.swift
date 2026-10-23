import Foundation

/// What a model returns for one capture. Field names match the JSON schema sent to
/// cloud models; the on-device model's output is converted into this too.
nonisolated struct ParsedCapture: Codable, Equatable {
    var items: [ParsedItem] = []
    /// Exact substrings of the input that were filler or abandoned corrections.
    var fillerPhrases: [String] = []
    /// One short question resolving the uncertain fields, or "".
    var followUpQuestion: String = ""

    init(items: [ParsedItem] = [], fillerPhrases: [String] = [], followUpQuestion: String = "") {
        self.items = items
        self.fillerPhrases = fillerPhrases
        self.followUpQuestion = followUpQuestion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([ParsedItem].self, forKey: .items) ?? []
        fillerPhrases = try c.decodeIfPresent([String].self, forKey: .fillerPhrases) ?? []
        followUpQuestion = try c.decodeIfPresent(String.self, forKey: .followUpQuestion) ?? ""
    }
}

/// One record. Every field is always present; "", 0, false, [] and "none" mean "not applicable".
/// Decoding is lenient so a model that drops an empty field doesn't fail the whole capture.
nonisolated struct ParsedItem: Codable, Equatable {
    var type = "task"
    var title = ""
    var amount = ""
    var amountIsApproximate = false
    var currency = ""
    var category = ""
    var account = ""
    var toAccount = ""
    var date = ""
    var time = ""
    var dateIsApproximate = false
    var repeatFrequency = "none"
    var repeatInterval = 1
    var repeatMonthDay = 0
    var repeatWeekdays: [Int] = []
    var reminderDaysBefore: [Int] = []
    var priority = "none"
    var listName = ""
    var billKind = "none"
    var expiryKind = "none"
    var note = ""
    var quote = ""
    /// 应收应付 only: who owes or is owed.
    var counterparty = ""
    var uncertainFields: [String] = []

    init() {}

    /// Takes the date (and time) worked out from the spoken words.
    mutating func apply(_ spoken: SpokenDate) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        date = formatter.string(from: spoken.date)
        if spoken.hasTime {
            formatter.dateFormat = "HH:mm"
            time = formatter.string(from: spoken.date)
        }
        if spoken.isApproximate {
            dateIsApproximate = true
            if !uncertainFields.contains("date") { uncertainFields.append("date") }
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys, _ fallback: String = "") -> String {
            (try? c.decodeIfPresent(String.self, forKey: key)) ?? fallback
        }
        func int(_ key: CodingKeys, _ fallback: Int) -> Int {
            if let value = try? c.decodeIfPresent(Int.self, forKey: key) { return value }
            if let text = try? c.decodeIfPresent(String.self, forKey: key), let value = Int(text) { return value }
            return fallback
        }
        func bool(_ key: CodingKeys) -> Bool {
            (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? false
        }
        type = string(.type, "task")
        title = string(.title)
        // Some models emit the amount as a number despite the schema.
        if let number = try? c.decodeIfPresent(Double.self, forKey: .amount) {
            amount = Decimal(number).inputText
        } else {
            amount = string(.amount)
        }
        amountIsApproximate = bool(.amountIsApproximate)
        currency = string(.currency)
        category = string(.category)
        account = string(.account)
        toAccount = string(.toAccount)
        date = string(.date)
        time = string(.time)
        dateIsApproximate = bool(.dateIsApproximate)
        repeatFrequency = string(.repeatFrequency, "none")
        repeatInterval = int(.repeatInterval, 1)
        repeatMonthDay = int(.repeatMonthDay, 0)
        repeatWeekdays = (try? c.decodeIfPresent([Int].self, forKey: .repeatWeekdays)) ?? []
        reminderDaysBefore = (try? c.decodeIfPresent([Int].self, forKey: .reminderDaysBefore)) ?? []
        priority = string(.priority, "none")
        listName = string(.listName)
        billKind = string(.billKind, "none")
        expiryKind = string(.expiryKind, "none")
        note = string(.note)
        quote = string(.quote)
        counterparty = string(.counterparty)
        uncertainFields = (try? c.decodeIfPresent([String].self, forKey: .uncertainFields)) ?? []
    }
}

/// A provider-neutral schema, rendered into each provider's dialect. Every property
/// is required and nothing is nullable: that is the one shape all three providers
/// (and strict mode) accept without special cases.
nonisolated indirect enum SchemaNode {
    case object([Property])
    case array(SchemaNode, description: String)
    case string(description: String, options: [String]? = nil)
    case integer(description: String)
    case boolean(description: String)

    struct Property {
        let name: String
        let node: SchemaNode
        /// Gemini may leave it out when it has nothing to say. Claude and OpenAI strict mode
        /// require every property, so for them it stays required.
        let isOptional: Bool
        init(_ name: String, _ node: SchemaNode, optional: Bool = false) {
            self.name = name
            self.node = node
            self.isOptional = optional
        }
    }

    /// JSON Schema for Claude structured outputs and OpenAI strict mode.
    var jsonSchema: [String: Any] {
        switch self {
        case .object(let properties):
            return [
                "type": "object",
                "properties": Dictionary(uniqueKeysWithValues: properties.map { ($0.name, $0.node.jsonSchema) }),
                "required": properties.map(\.name),
                "additionalProperties": false,
            ]
        case .array(let items, let description):
            return ["type": "array", "items": items.jsonSchema, "description": description]
        case .string(let description, let options):
            var node: [String: Any] = ["type": "string", "description": description]
            if let options { node["enum"] = options }
            return node
        case .integer(let description):
            return ["type": "integer", "description": description]
        case .boolean(let description):
            return ["type": "boolean", "description": description]
        }
    }

    /// Gemini's OpenAPI-style schema (`responseSchema`). Only the essential properties are
    /// required, so the model doesn't spend output tokens on a page of empty fields.
    var geminiSchema: [String: Any] {
        switch self {
        case .object(let properties):
            return [
                "type": "OBJECT",
                "properties": Dictionary(uniqueKeysWithValues: properties.map { ($0.name, $0.node.geminiSchema) }),
                "required": properties.filter { !$0.isOptional }.map(\.name),
                "propertyOrdering": properties.map(\.name),
            ]
        case .array(let items, let description):
            return ["type": "ARRAY", "items": items.geminiSchema, "description": description]
        case .string(let description, let options):
            var node: [String: Any] = ["type": "STRING", "description": description]
            if let options {
                node["enum"] = options
                node["format"] = "enum"
            }
            return node
        case .integer(let description):
            return ["type": "INTEGER", "description": description]
        case .boolean(let description):
            return ["type": "BOOLEAN", "description": description]
        }
    }
}

nonisolated enum CaptureSchema {
    static let itemTypes = ["task", "expense", "income", "transfer", "bill", "expiry", "note", "receivable", "payable"]
    /// On-device models choose among fewer: owed money is spotted afterwards by OutstandingCues.
    static let localItemTypes = ["task", "expense", "income", "transfer", "bill", "expiry", "note"]
    static let uncertainFieldNames = ["title", "amount", "date", "category", "account"]

    static let capture: SchemaNode = .object([
        .init("items", .array(item, description: "Every record mentioned, in the order mentioned.")),
        .init("fillerPhrases", .array(.string(description: "An exact substring of the input."),
                                      description: "Exact substrings of the input that are filler words, hesitations, repetitions or abandoned self-corrections."),
              optional: true),
        .init("followUpQuestion", .string(description: "One short question, in the input's language, that resolves every uncertain amount or date. Empty string if nothing is uncertain."),
              optional: true),
    ])

    static let item: SchemaNode = .object([
        .init("type", .string(description: "Record type.", options: itemTypes)),
        .init("title", .string(description: "Short name in the input's language, e.g. 午餐, 信用卡还款, 护照, 交季度报告. For notes: the existing note it belongs to, exactly as listed, or a short new name.")),
        .init("amount", .string(description: "Plain decimal number without symbols or separators, e.g. 35 or 2180.5. Empty if no amount."), optional: true),
        .init("amountIsApproximate", .boolean(description: "True when the amount was vague (两千多, 大概) and estimated."), optional: true),
        .init("currency", .string(description: "ISO 4217 code when a currency is named (美元 → USD); empty for the default currency."), optional: true),
        .init("category", .string(description: "For expense, income and bill: the closest category name from the provided list. Empty for other types."), optional: true),
        .init("account", .string(description: "Closest account name from the provided list, or empty. For transfers and bills: the paying account."), optional: true),
        .init("toAccount", .string(description: "Transfers only: the receiving account name, or empty. Credit-card bills: the card being repaid."), optional: true),
        .init("date", .string(description: "YYYY-MM-DD. Tasks: due date. Expenses/income: when it happened. Bills: next due date. Expiry: expiry date. Empty if none."), optional: true),
        .init("time", .string(description: "HH:mm, 24-hour, only when a clock time is stated or clearly implied. Otherwise empty."), optional: true),
        .init("dateIsApproximate", .boolean(description: "True when only the month (or a vague time) is known."), optional: true),
        .init("repeatFrequency", .string(description: "How the record repeats.", options: ["none", "daily", "weekly", "monthly", "yearly"]), optional: true),
        .init("repeatInterval", .integer(description: "Repeat every N units; 1 when not repeating."), optional: true),
        .init("repeatMonthDay", .integer(description: "Monthly only: day of month 1-31, or -1 for the last day. 0 otherwise."), optional: true),
        .init("repeatWeekdays", .array(.integer(description: "1 = Sunday … 7 = Saturday."), description: "Weekly only: the weekdays. Workdays = [2,3,4,5,6]. Empty otherwise."), optional: true),
        .init("reminderDaysBefore", .array(.integer(description: "Days before the date; 0 = on the day."), description: "When to remind. Empty for expenses, income and transfers."), optional: true),
        .init("priority", .string(description: "Tasks only; high only when urgency is expressed (急, 重要, 一定要).", options: ["none", "low", "medium", "high"]), optional: true),
        .init("listName", .string(description: "Tasks only: a context like 工作 or 家庭 when clear, else empty."), optional: true),
        .init("billKind", .string(description: "Bills only.", options: ["none"] + BillKind.allCases.map(\.rawValue)), optional: true),
        .init("expiryKind", .string(description: "Expiry items only.", options: ["none"] + ExpiryKind.allCases.map(\.rawValue)), optional: true),
        .init("note", .string(description: "For notes: the content to keep, tidied (no filler) with every fact kept. For other types: useful details not captured elsewhere, else empty."), optional: true),
        .init("quote", .string(description: "For a task or bill that comes from a sentence also kept in a note in this input: that exact sentence from the note's text. Else empty."), optional: true),
        .init("counterparty", .string(description: "Receivable and payable only: who owes or is owed, as said (张三, 客户, 装修师傅). Else empty."), optional: true),
        .init("uncertainFields", .array(.string(description: "Field name.", options: uncertainFieldNames),
                                        description: "Fields you had to guess."), optional: true),
    ])
}

/// What the model needs to know about "now" and the person's ledger.
nonisolated struct CaptureContext {
    var now: Date
    var timeZone: TimeZone
    var baseCurrency: String
    var expenseCategories: [String]
    var incomeCategories: [String]
    var accounts: [(name: String, kind: String)]
    /// Names of bills and expiry items that already exist, so the model reuses them.
    var existingBills: [String] = []
    var existingExpiries: [String] = []
    var existingNotes: [String] = []

    var nowDescription: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm, EEEE"
        return "\(formatter.string(from: now)) (\(timeZone.identifier))"
    }

    /// Short instructions for an open model on the phone, which re-reads them on every request
    /// at a few hundred tokens a second: only what it needs to pick types, names, amounts and time words.
    var compactInstructions: String {
        """
        Turn the person's spoken note into records. Ignore filler words (嗯, 呃, 那个, 就是, 然后). \
        One record per thing mentioned. Amounts in digits (三十五 → 35, 两千一百八 → 2180). \
        when: the time words exactly as said. \
        Progress on an ongoing matter (装修, 看病, 孩子, 项目) is also a note, named after an existing note when one fits; \
        a step it mentions for a later day is also a task. \
        Words that only say which note it goes in (在装修笔记下加一条, 记到装修里) choose the note's title.
        Now: \(nowDescription)
        Expense categories: \(expenseCategories.joined(separator: ", "))
        Income categories: \(incomeCategories.joined(separator: ", "))
        Existing notes: \(existingNotes.isEmpty ? "none" : existingNotes.joined(separator: ", "))
        """
    }

    /// System instructions shared by every provider.
    var instructions: String {
        let accountList = accounts.map { "\($0.name) (\($0.kind))" }.joined(separator: ", ")
        return """
        You turn a person's quick, messy note into structured records for their personal organizer. \
        The note is often a voice transcript full of filler words (嗯, 啊, 那个, 然后, 就是), repetitions and self-corrections.

        Context
        - Now: \(nowDescription)
        - Default currency: \(baseCurrency)
        - Expense categories: \(expenseCategories.joined(separator: ", "))
        - Income categories: \(incomeCategories.joined(separator: ", "))
        - Accounts: \(accountList)
        - Existing bills: \(existingBills.isEmpty ? "none" : existingBills.joined(separator: ", "))
        - Existing expiry items: \(existingExpiries.isEmpty ? "none" : existingExpiries.joined(separator: ", "))
        - Existing notes: \(existingNotes.isEmpty ? "none" : existingNotes.joined(separator: ", "))

        Record types
        - task: something to do. date/time = when it is due.
        - expense / income: money already spent or received. date = when it happened; default today.
        - transfer: money moved between the person's own accounts.
        - receivable: money someone owes the person that hasn't arrived yet (张三还欠我两千, 借给小王五千, 客户尾款还没到). date = when it's expected, if said.
        - payable: money the person owes someone and hasn't paid yet (还欠装修师傅三千工钱, 跟李四借了两千). date = when it's due, if said.
        - bill: a payment due in the future, usually repeating (credit card repayment, rent, utilities, loan, subscription). date = next due date.
        - expiry: a document, insurance policy, contract, warranty or membership that expires. date = expiry date.
        - note: information worth keeping rather than acting on: progress on an ongoing matter (装修, 看病, 孩子, 项目), what someone said, observations, ideas, reference details (passwords, contacts, sizes). Use it only when the person is recording something, never for a plain expense or to-do. Prefer an existing note when the topic matches. Words that only say which note it goes in (在装修这个笔记下加一条, 记到装修里, 放进装修记录) choose its title and are left out of the note text.

        Rules
        - One note can hold several records of different types. Return each one separately, in the order mentioned. Ignore anything that is not a record.
        - Self-corrections keep the final value: "三十，不对，四十" means 40.
        - Resolve relative dates (今天, 明天, 后天, 下周五, 月底, 明年三月) against Now.
        - If only the month is known, use the 1st of that month, set dateIsApproximate, and add "date" to uncertainFields.
        - Convert Chinese numerals to digits: 两千一百八 → 2180. For vague amounts (两千多, 大概三百) give your best estimate, set amountIsApproximate, and add "amount" to uncertainFields.
        - category: for every expense, income and bill, pick the closest name from the category lists above (装修、瓷砖 → a housing category, 打车 → a transport one); use the catch-all one only when nothing fits. account: a name from the list, or empty. Never invent new names.
        - Bills usually repeat monthly on the due day: repeatFrequency "monthly", repeatMonthDay = that day. Default reminderDaysBefore [3, 0].
        - Expiry items: default reminderDaysBefore [90, 30, 7] for documents, [30, 7, 0] for everything else.
        - When the note refers to an existing bill or expiry item, use exactly its existing name as the title.
        - A sentence inside a note that needs doing at a time (师傅说下周三铺砖) also becomes a task, with quote = that exact sentence from the note text. Money spent that the note mentions also becomes an expense.
        - Write title, note and followUpQuestion in the same language as the note.
        - fillerPhrases must be exact substrings of the note.
        - If the note ends with lines marked 补充 (or "Answer:"), they answer your earlier question and override earlier values.
        """
    }
}
