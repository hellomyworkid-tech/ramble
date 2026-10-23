import Foundation
import FoundationModels

/// The tidied note plus reminder suggestions. Field names match the cloud schema.
nonisolated struct OrganizedNote: Codable, Equatable {
    var cleanedText: String = ""
    /// A short name for an untitled note; empty when the note already has one.
    var title: String = ""
    var reminders: [ReminderSuggestion] = []
    /// The person asked for this to be marked as a key point (「标记一下重点」).
    var markAsKeyPoint = false

    init(cleanedText: String = "", title: String = "", reminders: [ReminderSuggestion] = [], markAsKeyPoint: Bool = false) {
        self.markAsKeyPoint = markAsKeyPoint
        self.cleanedText = cleanedText
        self.title = title
        self.reminders = reminders
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cleanedText = (try? c.decodeIfPresent(String.self, forKey: .cleanedText)) ?? ""
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        reminders = (try? c.decodeIfPresent([ReminderSuggestion].self, forKey: .reminders)) ?? []
        markAsKeyPoint = (try? c.decodeIfPresent(Bool.self, forKey: .markAsKeyPoint)) ?? false
    }
}

nonisolated struct ReminderSuggestion: Codable, Equatable {
    /// The sentence as it appears in `cleanedText`.
    var quote: String = ""
    /// A short action, e.g. "铺砖".
    var title: String = ""
    var date: String = ""
    var time: String = ""

    init(quote: String = "", title: String = "", date: String = "", time: String = "") {
        self.quote = quote
        self.title = title
        self.date = date
        self.time = time
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quote = (try? c.decodeIfPresent(String.self, forKey: .quote)) ?? ""
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        date = (try? c.decodeIfPresent(String.self, forKey: .date)) ?? ""
        time = (try? c.decodeIfPresent(String.self, forKey: .time)) ?? ""
    }

    var dueDate: Date? { DraftParsing.date(date, time: time) }
}

/// How far tidying goes.
nonisolated enum NoteTidyStyle: String, CaseIterable, Identifiable {
    /// Rewritten into clear sentences: order straightened, repeats merged, punctuation added.
    case fluent
    /// Only filler and repeats taken out; the wording stays as said.
    case light

    static let key = "notes.tidyStyle"
    var id: String { rawValue }

    static var current: NoteTidyStyle {
        NoteTidyStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .fluent
    }

    var title: LocalizedStringResource {
        switch self {
        case .fluent: "理顺语句"
        case .light: "只去口头禅"
        }
    }
}

/// Tidies a dictated or typed passage for a note, keeping every fact, and finds
/// sentences that call for a reminder.
nonisolated enum NoteOrganizer {
    static let schema: SchemaNode = .object([
        .init("cleanedText", .string(description: "The passage tidied up: filler, hesitations and repetitions removed, punctuation fixed, split into short paragraphs or a list where it helps. Every fact kept.")),
        .init("title", .string(description: "A short name for the note (at most 10 characters) when the note has no name yet; otherwise empty."),
              optional: true),
        .init("reminders", .array(.object([
            .init("quote", .string(description: "The exact sentence from cleanedText that calls for action at a time.")),
            .init("title", .string(description: "The action in a few words, e.g. 铺砖, 复查血常规.")),
            .init("date", .string(description: "YYYY-MM-DD, resolved against Now.")),
            .init("time", .string(description: "HH:mm 24-hour when stated, else empty."), optional: true),
        ]), description: "One per sentence that needs doing at a specific time or by a deadline. Empty when there are none."),
              optional: true),
        .init("markAsKeyPoint", .boolean(description: "true only when the person asks for this to be marked as important or a key point (标记重点, 划重点, 标为重要, 加星标)."),
              optional: true),
    ])

    static func instructions(noteTitle: String, existingReminders: Set<String> = [], now: Date, timeZone: TimeZone = .current,
                             style: NoteTidyStyle = .current) -> String {
        let context = CaptureContext(now: now, timeZone: timeZone, baseCurrency: "", expenseCategories: [], incomeCategories: [], accounts: [])
        let name = noteTitle.trimmed.isEmpty ? "an untitled note" : "the note \"\(noteTitle)\""
        let known = existingReminders.isEmpty ? "" : """

        - The note already has these reminders; don't suggest them again: \(existingReminders.sorted().joined(separator: "; ")).
        """
        return """
        You tidy up a passage the person dictated or typed into \(name) in their notebook. \
        It is often a voice transcript with filler words (嗯, 啊, 那个, 然后, 就是), repetitions and self-corrections.

        Now: \(context.nowDescription)

        Rules
        \(style == .fluent ? fluentRules : lightRules)
        - Words addressed to the app (标记一下重点, 划重点, 标为重要, 加个星标) aren't part of the note: leave them out of cleanedText and set markAsKeyPoint.
        - Write in the same language as the passage.
        - For each sentence that calls for action at a specific time or by a deadline (下周三铺砖, 三个月后复查, 月底前交), add a reminder: quote is that exact sentence as it appears in cleanedText; resolve relative dates against Now.
        - title only when the note has no name yet.\(known)
        """
    }

    /// Open models on the phone: a short brief in Chinese, and the text back, nothing else.
    /// Tried on Qwen3 4B against real dictation (see RambleTests/NoteTidyFixtures): an English
    /// brief left long unpunctuated passages as they were, and asking for reminders as well made
    /// it copy dates from Now and drop sentences.
    static func openInstructions(_ style: NoteTidyStyle, english: Bool = false) -> String {
        if english { return englishInstructions(style) }
        let common = """
        你是笔记整理助手。用户口述了一段话（语音转文字，常常没有标点、有口头禅、有重复、语序乱）。
        """
        switch style {
        case .fluent:
            return common + """
            请把它改写成通顺的书面文字，就像本人认真写下来的一样：
            1. 加上逗号、句号、问号，分成短句。
            2. 删掉口头禅和停顿词：嗯、呃、啊、那个、这个、就是、然后、比如说。删掉重复的话和说了一半又改口的部分（保留最后的说法）。
            3. 语序混乱就理顺；同一件事说了两遍就合并成一句。
            4. 保持本人的口吻和人称，原话是“我”就写“我”，不要改成“用户说”“用户反映”，也不要写得像报告。
            5. 每个事实和细节都要保留：数字、金额、日期、时间、次数、条件（如“过了很长时间”“第一次”“今天”）、人名、地名、东西的名字、原因、问题。问句仍然是问句。不要添加内容，不要总结，不要回答问题，不要给建议。
            6. 全部用中文书写；原话里本来就是英文的词（如 APP、bug）照抄。

            示例
            原话：嗯那个孩子学校，就是老师说呃下周一要交那个春游的钱，然后一百二，春游是下周五，就是周五去植物园
            整理：孩子学校的老师说，下周五去植物园春游，春游的钱一百二，下周一要交。
            原话：我想在首页加一个那个就是按钮可以一键清空然后不用一个一个删
            整理：我想在首页加一个按钮，可以一键清空，不用一个一个删。
            原话：呃有时候就是隔了好几天吧再打开这个那个页面会白屏一下这个是不是网络的问题
            整理：有时候隔了好几天再打开这个页面，会白屏一下，这是不是网络的问题？
            """
        case .light:
            return common + """
            请只做最少的整理：
            1. 加上逗号、句号、问号，分成短句。
            2. 删掉口头禅和停顿词：嗯、呃、啊、那个、这个、就是、然后。删掉重复的话和说了一半又改口的部分（保留最后的说法）。
            3. 其余每个字都保留原样，不要改写，不要调换顺序，不要添加内容。
            4. 全部用中文书写；原话里本来就是英文的词（如 APP、bug）照抄。

            示例
            原话：我想在首页加一个那个就是按钮可以一键清空然后不用一个一个删
            整理：我想在首页加一个按钮，可以一键清空，不用一个一个删。
            """
        }
    }

    /// The same brief for someone who dictates in English: kept in English, no translating.
    static func englishInstructions(_ style: NoteTidyStyle) -> String {
        let common = "You tidy up what the person dictated (speech to text: often no punctuation, filler words, repeats, jumbled order). "
        switch style {
        case .fluent:
            return common + """
            Rewrite it as clear written sentences, as they would have written it themselves:
            1. Add commas, full stops and question marks; use short sentences.
            2. Delete filler (um, uh, like, you know, so, I mean) and repeated words; for self-corrections keep the final version.
            3. Put a jumbled order right and merge what was said twice.
            4. Keep their own voice and person ("I" stays "I"); don't make it formal.
            5. Keep every fact: numbers, amounts, dates, times, names, places, reasons, problems. Questions stay questions. \
            Add nothing, don't summarize, don't answer, don't give advice.
            6. Write in English, as said; don't translate.
            """
        case .light:
            return common + """
            Do as little as possible:
            1. Add commas, full stops and question marks; use short sentences.
            2. Delete filler (um, uh, like, you know) and repeated words; for self-corrections keep the final version.
            3. Keep every other word as said, in the same order. Add nothing. Write in English, as said; don't translate.
            """
        }
    }

    /// Tidies with the open model: the chosen style, then 只去口头禅 if that drops or changes
    /// something. If both fail, the cloud takes it when allowed; otherwise the rule-tidied words.
    static func tidyWithOpenModel(_ text: String, style: NoteTidyStyle = .current, attempt: AIAttempt = .first) async throws -> String {
        let english = !Punctuation.isMostlyChinese(text)
        for pass in style == .fluent ? [NoteTidyStyle.fluent, .light] : [.light] {
            let session = LocalAI.makeSession(instructions: openInstructions(pass, english: english))
            do {
                let options = LocalAI.organizeOptions(for: text, attempt: attempt)
                let written = english
                    ? try await session.respond(to: text, generating: OpenTidiedEnglishText.self, options: options).content.cleanedText
                    : try await session.respond(to: text, generating: OpenTidiedText.self, options: options).content.cleanedText
                let cleaned = FillerCleaner.clean(written.trimmed)
                if isFaithful(cleaned, to: text, style: pass) { return cleaned }
            } catch let error as CancellationError {
                throw error
            } catch {
                // Cut off at its length cap: try the lighter pass.
            }
        }
        if AISettings.mode == .auto, AIAttempt.cloudIsAvailable, AISettings.hasCloudConsent {
            throw HandOffToCloud()
        }
        return FillerCleaner.clean(text)
    }

    /// The clause of `text` a quote from an earlier wording most likely became: the one sharing
    /// the most of its characters, so a reminder still points at its sentence after a rewrite.
    static func anchor(_ quote: String, in text: String) -> String {
        let wanted = Set(ChineseNumerals.normalize(quote).filter { $0.isLetter || $0.isNumber })
        let best = ReminderFinder.clauses(of: text).max { lhs, rhs in
            Set(ChineseNumerals.normalize(lhs)).intersection(wanted).count < Set(ChineseNumerals.normalize(rhs)).intersection(wanted).count
        }
        guard let best, Set(ChineseNumerals.normalize(best)).intersection(wanted).count * 2 >= wanted.count else { return "" }
        return best
    }

    /// Not an `AIError`, so the router moves on to the cloud instead of reporting it.
    struct HandOffToCloud: Error {}

    /// Rewrite into what the person would have written: meaning first, wording second.
    static let fluentRules = """
    - Work out what the person means, then write it as clear, natural written sentences with proper punctuation, \
    as they would have written it themselves. Delete filler words (嗯, 呃, 啊, 那个, 就是, 然后 used as pauses), false starts, \
    repeated phrases and abandoned self-corrections (keep the final version). Put clauses in a sensible order when the \
    spoken order is jumbled, and merge sentences that say the same thing twice.
    - Keep every fact: every number, amount, date, time word, name, place, measurement and symptom, and keep questions as questions. \
    Never add facts, opinions, advice or answers, and don't summarize details away. Keep the person's own voice; don't make it formal. \
    It should be about as long as what was said, minus the filler.
    - Split into short paragraphs, or a list when the person lists several things.
    - Example. Said: 嗯那个孩子学校，就是老师说呃下周一要交那个春游的钱，然后一百二，春游是下周五，就是周五去植物园 \
    → Written: 孩子学校的老师说，下周五春游去植物园，春游的钱一百二，下周一要交。
    """

    /// Only filler out; wording kept.
    static let lightRules = """
    - Delete every filler word wherever it appears: 嗯, 呃, 啊, and 那个, 就是, 然后, 还有就是 when they only fill a pause. \
    Delete hesitations and repeated words; for self-corrections keep the final version. Fix punctuation. \
    Split into short paragraphs, or a list when the person is listing things.
    - Keep every other word and every clause, even small ones such as 今天师傅来看了一下 or 有点高, and every fact, number, \
    name, price and measurement. Never add information, never reword, never summarize details away, never give advice.
    """

    /// How a reminder is described to the model and matched against its suggestions.
    static func reminderKey(title: String, date: String) -> String {
        "\(title.trimmed) \(date)"
    }

    static func dayString(_ date: Date, timeZone: TimeZone = .current) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day())
    }

    /// Small models don't always heed "don't repeat"; drop suggestions the note already has.
    static func droppingKnown(_ note: OrganizedNote, existing: Set<String>) -> OrganizedNote {
        var result = note
        result.reminders.removeAll { existing.contains(reminderKey(title: $0.title, date: $0.date)) }
        return result
    }

    static func organize(_ text: String, noteTitle: String, existingReminders: Set<String> = [],
                         now: Date = .now, attempt: AIAttempt = .first) async throws -> (OrganizedNote, CaptureSource) {
        // 「给这条标记一下重点」 is for the app, not the note: taken out here, carried out on saving.
        let commands = NoteCommands.extract(text)
        let input = commands.text.trimmed.isEmpty ? text : commands.text
        var (organized, source) = try await organizeRaw(input, noteTitle: noteTitle, existingReminders: existingReminders,
                                                        now: now, attempt: attempt)
        organized.markAsKeyPoint = organized.markAsKeyPoint || commands.markAsKeyPoint
        return (droppingKnown(organized, existing: existingReminders), source)
    }

    private static func organizeRaw(_ text: String, noteTitle: String, existingReminders: Set<String>,
                                    now: Date, attempt: AIAttempt) async throws -> (OrganizedNote, CaptureSource) {
        #if DEBUG
        if MockCapture.isEnabled {
            try await Task.sleep(for: .milliseconds(600))
            return (MockCapture.organizedNote(for: text, now: now), .onDevice)
        }
        #endif
        let instructions = instructions(noteTitle: noteTitle, existingReminders: existingReminders, now: now)
        return try await AIRouter.run(
            attempt: attempt,
            onDevice: {
                if LocalAI.usesOpenModel {
                    // The model only rewrites the text; reminders come from its time words, by rule.
                    let cleaned = try await tidyWithOpenModel(text, attempt: attempt)
                    return OrganizedNote(cleanedText: cleaned, reminders: ReminderFinder.find(in: cleaned, now: now))
                }
                let session = LocalAI.makeSession(instructions: instructions)
                let response = try await session.respond(to: text, generating: OnDeviceOrganizedNote.self,
                                                         options: LocalAI.organizeOptions(for: text, attempt: attempt))
                return polished(response.content, original: text, now: now)
            },
            isUsable: { isUsable($0, original: text) },
            isEmpty: { $0.cleanedText.trimmed.isEmpty },
            cloud: { client in
                try await ThinkingPlanner.run(ThinkingPlanner.plan(for: .organize(text)).retried(attempt), client: client,
                                              isUsable: { isUsable($0, original: text) && keepsNumbers($0.cleanedText, original: text) }) {
                    try await $0.generate(OrganizedNote.self, instructions: instructions, input: text, schema: schema)
                }.0
            }
        )
    }

    /// On-device output, made safe: leftover filler removed, dates worked out from the spoken words,
    /// and, if the model dropped part of what was said, the rule-cleaned original instead.
    static func polished(_ result: OnDeviceOrganizedNote, original: String, now: Date,
                         style: NoteTidyStyle = .current) -> OrganizedNote {
        var organized = result.organized
        organized.cleanedText = FillerCleaner.clean(organized.cleanedText)
        if !isFaithful(organized.cleanedText, to: original, style: style) {
            organized.cleanedText = FillerCleaner.clean(original)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        organized.reminders = zip(organized.reminders, result.reminders).compactMap { reminder, raw in
            var reminder = reminder
            reminder.title = reminderTitle(reminder.title)
            guard !raw.when.trimmed.isEmpty else { return reminder }
            // Time words that aren't a time (e.g. "校服钱两百五要交") leave nothing to remind on,
            // unless the sentence itself has one.
            guard let spoken = SpokenDate.resolve(raw.when, now: now) ?? SpokenDate.resolve(raw.quote, now: now) else { return nil }
            var resolved = reminder
            formatter.dateFormat = "yyyy-MM-dd"
            resolved.date = formatter.string(from: spoken.date)
            formatter.dateFormat = "HH:mm"
            resolved.time = spoken.hasTime ? formatter.string(from: spoken.date) : ""
            return resolved
        }
        return organized
    }

    /// "提醒：下周三铺砖" → "下周三铺砖": the list already says it's a reminder.
    static func reminderTitle(_ title: String) -> String {
        let trimmed = title.replacingOccurrences(of: #"^\s*(?:提醒(?:我|一下)?|记得|别忘了)\s*[:：，,]?\s*"#, with: "", options: .regularExpression).trimmed
        return trimmed.isEmpty ? title.trimmed : trimmed
    }

    /// Whether a tidied passage still says what was said. Kept wording must keep nearly every
    /// character; a rewrite may reword and merge repeats, but every number must survive and none
    /// may appear from nowhere (an echoed date, a made-up amount), and the length must stay close.
    static func isFaithful(_ cleaned: String, to original: String, style: NoteTidyStyle) -> Bool {
        guard isPunctuated(cleaned, original: original), !addsVoices(cleaned, original: original) else { return false }
        switch style {
        case .light:
            return coverage(of: cleaned, against: original) >= 0.85 && coverage(of: original, against: cleaned) >= 0.9
        case .fluent:
            func letters(_ text: String) -> Int { SpokenDate.normalizedNumbers(text).filter { $0.isLetter || $0.isNumber }.count }
            let said = letters(FillerCleaner.clean(original))
            guard said > 0 else { return true }
            let ratio = Double(letters(cleaned)) / Double(said)
            return keepsNumbers(cleaned, original: original)
                && ratio >= 0.4 && ratio <= 1.3
                && contentCoverage(of: cleaned, against: original) >= 0.75
                && weakestPartCoverage(of: cleaned, against: original) >= 0.5
                && coverage(of: original, against: cleaned) >= 0.7
        }
    }

    /// Dictation of more than a sentence comes back with sentences: a model that copied a long
    /// unpunctuated run back hasn't tidied anything.
    static func isPunctuated(_ cleaned: String, original: String) -> Bool {
        let letters = cleaned.filter { $0.isLetter || $0.isNumber }.count
        guard letters > 30 else { return true }
        let marks = cleaned.filter { "，,。.；;！!？?、：:\n".contains($0) }.count
        return marks >= max(1, letters / 40)
    }

    /// Small models sometimes narrate (「用户反映」) or slip into English (「他 said」).
    static func addsVoices(_ cleaned: String, original: String) -> Bool {
        if cleaned.contains("用户"), !original.contains("用户") { return true }
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().matches(of: #/[a-z]{2,}/#).map { String($0.output) })
        }
        return !words(cleaned).subtracting(words(original)).isEmpty
    }

    /// The worst-kept part of what was said. A rewrite may drop a filler phrase or swap a word,
    /// but a whole clause gone (今天师傅来看了一下) leaves that part nearly empty. Unpunctuated
    /// dictation is cut into runs of about a dozen content characters.
    static func weakestPartCoverage(of cleaned: String, against original: String) -> Double {
        func content(_ text: String) -> [Character] {
            ChineseNumerals.normalize(text).filter { ($0.isLetter || $0.isNumber) && !functionCharacters.contains($0) }
                .map { Character($0.lowercased()) }
        }
        let kept = Set(content(cleaned))
        var parts: [[Character]] = []
        for clause in ReminderFinder.clauses(of: FillerCleaner.clean(original)) {
            let characters = content(clause)
            stride(from: 0, to: characters.count, by: 12).forEach { parts.append(Array(characters[$0..<min($0 + 12, characters.count)])) }
        }
        let scores = parts.map(Set.init).filter { $0.count >= 4 }.map { Double($0.intersection(kept).count) / Double($0.count) }
        return scores.min() ?? 1
    }

    /// Every number said is still there, and nothing new: 「两千一百八」 and 「2180」 count as the same.
    static func keepsNumbers(_ cleaned: String, original: String) -> Bool {
        let said = ChineseNumerals.significantNumbers(in: original)
        let written = ChineseNumerals.significantNumbers(in: cleaned)
        return said.isSubset(of: written) && written.isSubset(of: said)
    }

    /// Words that carry grammar rather than content; a rewrite may drop or swap them freely.
    private static let functionCharacters = Set("的了是在就这那个也还都和与跟把被很有吗呢吧啊呀嘛么嗯呃些之所以而且但如果因为然后要会说比如一下")

    /// The share of distinct content characters said that the tidied text still uses anywhere.
    /// Merging a repeat keeps them all; rewording swaps a few; dropping a clause loses several.
    static func contentCoverage(of cleaned: String, against original: String) -> Double {
        func content(_ text: String) -> Set<Character> {
            Set(ChineseNumerals.normalize(text).filter { ($0.isLetter || $0.isNumber) && !functionCharacters.contains($0) }.map { Character($0.lowercased()) })
        }
        let said = content(FillerCleaner.clean(original))
        guard !said.isEmpty else { return 1 }
        return Double(said.intersection(content(cleaned)).count) / Double(said.count)
    }

    /// The share of what was said (filler aside) that the tidied text still contains.
    static func coverage(of cleaned: String, against original: String) -> Double {
        func characters(_ text: String) -> [Character] {
            SpokenDate.normalizedNumbers(text).filter { $0.isLetter || $0.isNumber }
        }
        let reference = characters(FillerCleaner.clean(original))
        guard !reference.isEmpty else { return 1 }
        var available = Dictionary(characters(cleaned).map { ($0, 1) }, uniquingKeysWith: +)
        var kept = 0
        for character in reference where (available[character] ?? 0) > 0 {
            available[character, default: 0] -= 1
            kept += 1
        }
        return Double(kept) / Double(reference.count)
    }

    /// A small model can drop most of the text or invent dates; either sends the passage to the cloud.
    static func isUsable(_ note: OrganizedNote, original: String? = nil) -> Bool {
        let cleaned = note.cleanedText.trimmed
        guard !cleaned.isEmpty else { return false }
        if let original, cleaned.count < original.trimmed.count / 3 { return false }
        return note.reminders.allSatisfy { $0.dueDate != nil && !$0.title.trimmed.isEmpty }
    }
}

@Generable
nonisolated struct OnDeviceOrganizedNote {
    @Guide(description: "The passage written as clear sentences: filler removed, punctuation fixed, short paragraphs. Every fact kept.")
    var cleanedText: String
    @Guide(description: "A short name for an untitled note, else empty.")
    var title: String
    @Guide(description: "Sentences that call for action at a specific time.")
    var reminders: [OnDeviceReminderSuggestion]

    var organized: OrganizedNote {
        OrganizedNote(cleanedText: cleanedText, title: title, reminders: reminders.map {
            ReminderSuggestion(quote: $0.quote, title: $0.title, date: $0.date, time: $0.time)
        })
    }
}

@Generable
nonisolated struct OnDeviceReminderSuggestion {
    @Guide(description: "The exact sentence from cleanedText.")
    var quote: String
    @Guide(description: "The action in a few words.")
    var title: String
    @Guide(description: "The time words exactly as said in the passage, e.g. 下周三, 三个月以后, 下周四下午三点, 月底前.")
    var when: String
    @Guide(description: "YYYY-MM-DD")
    var date: String
    @Guide(description: "HH:mm or empty")
    var time: String
}
