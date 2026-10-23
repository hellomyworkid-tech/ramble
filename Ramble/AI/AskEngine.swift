import Foundation
import FoundationModels
import SwiftData

/// What AI hands back for a question the rules couldn't read: what to look up, never the
/// answer. Field names match the cloud schema.
nonisolated struct AIQueryPlan: Codable, Equatable {
    var subject = "expense"
    var measure = "total"
    var period = "none"
    var from = ""
    var to = ""
    var categories: [String] = []
    var keywords: [String] = []
    var taskState = "open"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subject = (try? c.decodeIfPresent(String.self, forKey: .subject)) ?? "expense"
        measure = (try? c.decodeIfPresent(String.self, forKey: .measure)) ?? "total"
        period = (try? c.decodeIfPresent(String.self, forKey: .period)) ?? "none"
        from = (try? c.decodeIfPresent(String.self, forKey: .from)) ?? ""
        to = (try? c.decodeIfPresent(String.self, forKey: .to)) ?? ""
        categories = (try? c.decodeIfPresent([String].self, forKey: .categories)) ?? []
        keywords = (try? c.decodeIfPresent([String].self, forKey: .keywords)) ?? []
        taskState = (try? c.decodeIfPresent(String.self, forKey: .taskState)) ?? "open"
    }

    /// The plan the app runs: unknown values fall back, categories must be ones the person has.
    func plan(categories known: [CategoryInfo], now: Date) -> QueryPlan {
        let names = Set(known.map(\.name))
        var plan = QueryPlan(subject: QueryPlan.Subject(rawValue: subject) ?? .notes,
                             measure: QueryPlan.Measure(rawValue: measure) ?? .total,
                             period: PeriodResolver.preset(period, from: from, to: to, now: now),
                             categories: categories.filter(names.contains),
                             keywords: keywords.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(4).map { $0 },
                             taskState: QueryPlan.TaskState(rawValue: taskState) ?? .open)
        if plan.subject == .income || plan.subject == .expense {
            let isIncome = plan.subject == .income
            plan.categories = plan.categories.filter { name in known.first { $0.name == name }?.isIncome == isIncome }
        }
        return plan
    }
}

@Generable
nonisolated struct OnDeviceQueryPlan {
    @Guide(description: "expense: money spent. income: money received. balance: income minus spending. tasks: to-dos. bills: payments due. expiries: documents or insurance expiring. notes: anything written in their notebook.",
           .anyOf(QueryPlan.Subject.allCases.map(\.rawValue)))
    var subject: String
    @Guide(description: "total, count, average (per day), top (which categories took most), biggest (largest single entries), list, compare (with the previous period).",
           .anyOf(QueryPlan.Measure.allCases.map(\.rawValue)))
    var measure: String
    @Guide(description: "The time the question is about; none if not said; custom for other ranges.", .anyOf(PeriodResolver.presets))
    var period: String
    @Guide(description: "custom only: first day as yyyy-MM-dd, else empty.")
    var from: String
    @Guide(description: "custom only: last day as yyyy-MM-dd, else empty.")
    var to: String
    @Guide(description: "Category names from the list that the question is about.")
    var categories: [String]
    @Guide(description: "Short words to search for in notes, e.g. 咖啡, 装修, 血脂.")
    var keywords: [String]
    @Guide(description: "For to-dos: open, done or overdue.", .anyOf(QueryPlan.TaskState.allCases.map(\.rawValue)))
    var taskState: String

    var aiPlan: AIQueryPlan {
        var plan = AIQueryPlan()
        plan.subject = subject
        plan.measure = measure
        plan.period = period
        plan.from = from
        plan.to = to
        plan.categories = categories
        plan.keywords = keywords
        plan.taskState = taskState
        return plan
    }
}

/// An answer written from the person's own notes, with the excerpts it used.
nonisolated struct NoteAnswer: Codable, Equatable {
    var answer = ""

    init(answer: String = "") { self.answer = answer }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        answer = (try? c.decodeIfPresent(String.self, forKey: .answer)) ?? ""
    }
}

@Generable
nonisolated struct OnDeviceNoteAnswer {
    @Guide(description: "The answer in one to three short sentences, in the language of the question, using only the notes. Numbers and dates exactly as written.")
    var answer: String
}

/// Questions about the person's own records. Rules read the common ones on the phone; AI only
/// reads the rest, and only the question is sent for that. Numbers are always counted here.
enum AskEngine {
    static let planSchema: SchemaNode = .object([
        .init("subject", .string(description: "What the question is about.", options: QueryPlan.Subject.allCases.map(\.rawValue))),
        .init("measure", .string(description: "What to work out.", options: QueryPlan.Measure.allCases.map(\.rawValue))),
        .init("period", .string(description: "The time the question is about; none if not said; custom for other ranges.",
                                options: PeriodResolver.presets)),
        .init("from", .string(description: "custom only: first day as yyyy-MM-dd, else empty."), optional: true),
        .init("to", .string(description: "custom only: last day as yyyy-MM-dd, else empty."), optional: true),
        .init("categories", .array(.string(description: "A category name exactly as listed."),
                                   description: "Categories the question is about; empty for all."), optional: true),
        .init("keywords", .array(.string(description: "A short word."),
                                 description: "Words to search for in record notes or notebook entries, e.g. 咖啡, 滴滴, 装修, 血脂."), optional: true),
        .init("taskState", .string(description: "For to-dos only.", options: QueryPlan.TaskState.allCases.map(\.rawValue)), optional: true),
    ])

    static let noteSchema: SchemaNode = .object([
        .init("answer", .string(description: "The answer in one to three short sentences, using only the notes. Numbers and dates exactly as written. If the notes don't say, say so.")),
    ])

    static func planInstructions(categories: [CategoryInfo], now: Date) -> String {
        let expense = categories.filter { !$0.isIncome }.map(\.name).joined(separator: ", ")
        let income = categories.filter(\.isIncome).map(\.name).joined(separator: ", ")
        return """
        Someone asks a question about their own records in a personal organizer: spending, income, to-dos, bills, \
        expiry dates and notes. Say what to look up; don't answer it, the app counts the answer itself.
        Now: \(now.formatted(.iso8601.year().month().day())) (\(now.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "en_US")))))
        Expense categories: \(expense)
        Income categories: \(income)
        subject: expense, income, balance (income minus spending), tasks (to-dos), bills (payments due), \
        expiries (documents, insurance, contracts), notes (anything else they wrote down: test results, progress, what someone said).
        measure: total, count, average (per day), top (which categories took most), biggest (largest single entries), list, compare (with the period before).
        period: the time asked about, or none. Use custom with from and to (yyyy-MM-dd) for holidays and other ranges.
        categories: only names from the lists above. keywords: short words to search notes for. taskState: open, done or overdue.
        Example: 国庆打车花了多少 → {"subject":"expense","measure":"total","period":"custom","from":"2026-10-01","to":"2026-10-07","categories":["交通"],"keywords":["打车"],"taskState":"open"}
        """
    }

    /// Replies in the language the question was asked in.
    static func noteInstructions(for question: String) -> String {
        let chinese = Punctuation.isMostlyChinese(question)
        return """
        Answer the person's question from their own notebook entries below. Reply in \(chinese ? "Chinese" : "English"), \
        one to three short sentences. Use only what the entries say; give numbers and dates exactly as written. \
        If they don't answer it, reply \(chinese ? "笔记里没有写到。" : "Your notes don't say.")
        """
    }

    static func categories(in context: ModelContext) -> [CategoryInfo] {
        ((try? context.fetch(FetchDescriptor<LedgerCategory>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []).map {
            CategoryInfo(name: $0.name, isIncome: $0.kind == .income, parent: $0.parent?.name, seedKey: $0.seedKey)
        }
    }

    static func ask(_ question: String, context: ModelContext, now: Date = .now) async throws -> AskAnswer {
        let categories = categories(in: context)
        let rules = QuestionParser.parse(question, categories: categories, now: now)
        var plan = rules.plan
        var source = AskAnswer.Source.rules

        if !rules.confident {
            do {
                let (aiPlan, aiSource) = try await planWithAI(question, categories: categories, now: now)
                plan = aiPlan
                source = .ai(aiSource)
            } catch {
                // Without AI the rules' best reading still helps, unless they had none.
                if plan == nil { throw error }
            }
        }
        guard let plan else {
            return AskAnswer(headline: String(localized: "没太听懂，换个说法试试？比如「这个月吃饭花了多少」「这周还有哪些待办」。"))
        }
        if plan.subject == .notes {
            return try await answerFromNotes(question, plan: plan, context: context, planSource: source)
        }
        var answer = QueryRunner.run(plan, context: context, now: now)
        answer.source = source
        return answer
    }

    static func planWithAI(_ question: String, categories: [CategoryInfo], now: Date) async throws -> (QueryPlan, CaptureSource) {
        let instructions = planInstructions(categories: categories, now: now)
        let (raw, source) = try await AIRouter.run(
            onDevice: {
                let session = LocalAI.makeSession(instructions: instructions)
                let response = try await session.respond(to: question, generating: OnDeviceQueryPlan.self,
                                                         options: LocalAI.options(maximumTokens: 220))
                return response.content.aiPlan
            },
            isUsable: { QueryPlan.Subject(rawValue: $0.subject) != nil },
            isEmpty: { _ in false },
            cloud: { client in
                var client = client
                client.thinking = .fast
                return try await client.generate(AIQueryPlan.self, instructions: instructions, input: question, schema: planSchema)
            })
        return (raw.plan(categories: categories, now: now), source)
    }

    /// Finds the entries that mention the question's words and has AI answer from those alone.
    static func answerFromNotes(_ question: String, plan: QueryPlan, context: ModelContext,
                                planSource: AskAnswer.Source) async throws -> AskAnswer {
        let entries = QueryRunner.matchingEntries(plan.keywords, context: context)
        guard !entries.isEmpty else {
            return AskAnswer(headline: String(localized: "笔记里没找到相关的内容。"), source: planSource, plan: plan)
        }
        let input = String(localized: "问题：\(question)") + "\n\n" + entries.enumerated().map { index, entry in
            "[\(index + 1)] \(entry.note?.displayTitle ?? "笔记") · \(entry.date.formatted(.iso8601.year().month().day()))\n\(DocumentText.condensed(entry.text, limit: 600))"
        }.joined(separator: "\n\n")
        var answer = AskAnswer(headline: "", plan: plan)
        answer.items = entries.map(QueryRunner.noteItem)
        do {
            let (reply, source) = try await AIRouter.run(
                onDevice: {
                    let session = LocalAI.makeSession(instructions: noteInstructions(for: question))
                    let response = try await session.respond(to: input, generating: OnDeviceNoteAnswer.self,
                                                             options: LocalAI.options(maximumTokens: 200))
                    return NoteAnswer(answer: response.content.answer)
                },
                isUsable: { !$0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                isEmpty: { $0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                cloud: { client in
                    var client = client
                    client.thinking = .fast
                    return try await client.generate(NoteAnswer.self, instructions: noteInstructions(for: question), input: input, schema: noteSchema)
                })
            answer.headline = reply.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            answer.source = .ai(source)
        } catch let error as AIError {
            if case .needsConsent = error { throw error }
            // No AI to read them: the entries themselves are the answer.
            answer.headline = String(localized: "笔记里找到 \(entries.count) 条相关记录：")
            answer.source = planSource
        }
        return answer
    }
}
