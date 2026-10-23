import Foundation

/// The thinking setting: picked per request, or fixed.
nonisolated enum ThinkingSetting: String, CaseIterable, Identifiable {
    case auto, fast, balanced, thorough

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .auto: "自动"
        case .fast: "快速"
        case .balanced: "均衡"
        case .thorough: "深入"
        }
    }

    var fixed: AIThinking? {
        switch self {
        case .auto: nil
        case .fast: .fast
        case .balanced: .balanced
        case .thorough: .thorough
        }
    }
}

/// What a cloud request is for, with what the planner needs to size it.
nonisolated enum AITask {
    /// "记一下": a spoken or typed capture. `isFollowUp` when it carries an answer to a question.
    case capture(String, isFollowUp: Bool = false)
    /// Tidying a passage in a note.
    case organize(String)
    /// Reading photos and files: total characters of text, files, pages, and whether the model sees the originals.
    case document(characters: Int, files: Int, pages: Int, originals: Bool)
}

/// Picks how hard a cloud model thinks, from the request itself: no extra model call, so it
/// adds no time. Short captures always start fast and never go past "balanced"; only long
/// documents reach "thorough". A fast answer that fails the app's checks is retried once,
/// one level up, instead of starting every request slow.
nonisolated enum ThinkingPlanner {
    struct Plan: Equatable {
        var start: AIThinking
        /// The highest level a retry may use.
        var cap: AIThinking

        /// Asked for again (「重新整理」): start one level higher, within the cap.
        func retried(_ attempt: AIAttempt) -> Plan {
            guard attempt.isRetry, let next = start.next, next <= cap else { return self }
            return Plan(start: next, cap: cap)
        }
    }

    static func plan(for task: AITask, setting: ThinkingSetting = AISettings.thinkingSetting) -> Plan {
        if let fixed = setting.fixed { return Plan(start: fixed, cap: fixed) }
        switch task {
        case .capture(let text, let isFollowUp):
            let signals = Signals(text)
            // One or two sentences: always fast, whatever they contain.
            guard signals.length > 40 else { return Plan(start: .fast, cap: .balanced) }
            let busy = signals.length > 120 || signals.clauses >= 6 || signals.figures >= 4
                || signals.hasCorrection || (isFollowUp && signals.length > 80)
            return Plan(start: busy ? .balanced : .fast, cap: .balanced)

        case .organize(let text):
            let signals = Signals(text)
            let busy = signals.length > 200 || (signals.length > 80 && signals.hasCorrection)
            return Plan(start: busy ? .balanced : .fast, cap: .balanced)

        case .document(let characters, let files, let pages, let originals):
            // A receipt or a one-line note in a photo needs no deliberation.
            if !originals, characters < 600, pages <= 1 { return Plan(start: .fast, cap: .balanced) }
            let large = characters > 8_000 || pages >= 6 || files >= 4
            return Plan(start: large ? .thorough : .balanced, cap: .thorough)
        }
    }

    /// Runs `attempt` at the planned level; when the answer fails `isUsable` (or comes back
    /// unreadable) and the plan allows, tries once more one level higher.
    static func run<T>(_ plan: Plan, client: CloudClient, isUsable: (T) -> Bool,
                       attempt: (CloudClient) async throws -> T) async throws -> (T, AIThinking) {
        var client = client
        client.thinking = plan.start
        var firstAnswer: T?
        var firstError: Error?
        do {
            let answer = try await attempt(client)
            if isUsable(answer) { return (answer, plan.start) }
            firstAnswer = answer
        } catch let error as AIError where error.isWorthRetrying {
            firstError = error
        }

        guard let next = plan.start.next, next <= plan.cap else {
            if let firstAnswer { return (firstAnswer, plan.start) }
            throw firstError ?? AIError.nothingFound
        }
        client.thinking = next
        do {
            let retry = try await attempt(client)
            if isUsable(retry) || firstAnswer == nil { return (retry, next) }
        } catch {
            if firstAnswer == nil { throw error }
        }
        // The retry did no better: keep the first answer for the person to fix up.
        return (firstAnswer!, plan.start)
    }

    /// What the planner reads from a passage. Filler is removed first, so rambling doesn't count as length.
    struct Signals {
        let length: Int
        let clauses: Int
        let figures: Int
        let hasCorrection: Bool

        init(_ text: String) {
            let cleaned = FillerCleaner.clean(text)
            length = cleaned.filter { $0.isLetter || $0.isNumber }.count
            clauses = cleaned.split { "，,。.；;！!？?\n".contains($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            let numbers = SpokenDate.normalizedNumbers(cleaned)
            figures = numbers.matches(of: #/\d+(?:\.\d+)?/#).count
            hasCorrection = ["不对", "不是不是", "说错", "改成", "应该是", "算了", "重新说"].contains(where: cleaned.contains)
        }
    }
}

extension AIThinking: Comparable {
    nonisolated static func < (lhs: AIThinking, rhs: AIThinking) -> Bool { lhs.index < rhs.index }

    nonisolated var next: AIThinking? {
        switch self {
        case .fast: .balanced
        case .balanced: .thorough
        case .thorough: nil
        }
    }
}

extension AIError {
    /// An answer that didn't parse or found nothing may come out right with more thought;
    /// network, key and quota errors won't.
    nonisolated var isWorthRetrying: Bool {
        switch self {
        case .badResponse, .nothingFound: true
        default: false
        }
    }
}
