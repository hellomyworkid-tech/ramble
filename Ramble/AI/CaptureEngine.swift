import Foundation

nonisolated enum CaptureSource: Equatable, Codable {
    case onDevice
    case cloud(AIProvider)

    var label: String {
        switch self {
        case .onDevice: LocalAI.engine == .open ? String(localized: "\(LocalAI.openModel.title) 本机处理") : String(localized: "本机处理")
        case .cloud(let provider): String(localized: "\(provider.displayName) 处理")
        }
    }
}

nonisolated struct CaptureOutcome {
    let capture: ParsedCapture
    let source: CaptureSource
    /// How hard the cloud model thought, when one was used.
    var thinking: AIThinking?
}

/// One go at an AI request: the first, or another one the person asked for (「重新整理」).
nonisolated struct AIAttempt: Equatable {
    /// 0 for the first try; each 重新整理 adds one.
    var number = 0
    /// Skip the phone and ask the cloud provider directly (「用云端整理」).
    var forcesCloud = false

    static let first = AIAttempt()

    var isRetry: Bool { number > 0 }

    func next(forcingCloud: Bool = false) -> AIAttempt {
        AIAttempt(number: number + 1, forcesCloud: forcingCloud)
    }

    /// Whether 「用云端整理」 can be offered: a provider is set up and the person allows the cloud.
    static var cloudIsAvailable: Bool {
        AISettings.mode != .onDevice && AISettings.cloudClient() != nil
    }
}

/// Decides who handles an AI request: the on-device model first (free, private), the
/// person's own cloud provider when the device can't or the result looks wrong.
nonisolated enum AIRouter {
    static func run<T>(attempt: AIAttempt = .first,
                       onDevice: () async throws -> T,
                       isUsable: (T) -> Bool,
                       isEmpty: (T) -> Bool,
                       cloud: (CloudClient) async throws -> T) async throws -> (T, CaptureSource) {
        let mode = attempt.forcesCloud ? AIMode.cloud : AISettings.mode
        var onDeviceFallback: T?

        if mode != .cloud {
            let status = LocalAI.status
            if status.isAvailable {
                do {
                    await ModelIdleRelease.languageModelInUse()
                    let result: T
                    do {
                        result = try await onDevice()
                        await ModelIdleRelease.languageModelIdle()
                    } catch {
                        await ModelIdleRelease.languageModelIdle()
                        throw error
                    }
                    if isUsable(result) { return (result, .onDevice) }
                    if mode == .onDevice {
                        guard !isEmpty(result) else { throw AIError.nothingFound }
                        return (result, .onDevice)
                    }
                    onDeviceFallback = result
                } catch let error as AIError {
                    throw error
                } catch {
                    if mode == .onDevice { throw AIError.onDeviceUnavailable(error.localizedDescription) }
                }
            } else if mode == .onDevice {
                throw AIError.onDeviceUnavailable(status.message)
            }
        }

        guard let client = AISettings.cloudClient() else {
            if let onDeviceFallback, !isEmpty(onDeviceFallback) { return (onDeviceFallback, .onDevice) }
            throw mode == .cloud ? AIError.missingKey(AISettings.provider) : AIError.cloudNotConfigured
        }
        guard AISettings.hasCloudConsent else { throw AIError.needsConsent(client.provider) }

        let result = try await cloud(client)
        guard !isEmpty(result) else { throw AIError.nothingFound }
        return (result, .cloud(client.provider))
    }

    /// Straight to the person's cloud provider, for work only it can do (looking at a file).
    /// The caller has asked the person for this particular send.
    static func runCloud<T>(isEmpty: (T) -> Bool, _ cloud: (CloudClient) async throws -> T) async throws -> (T, CaptureSource) {
        guard let client = AISettings.cloudClient() else { throw AIError.originalsNeedCloud }
        let result = try await cloud(client)
        guard !isEmpty(result) else { throw AIError.nothingFound }
        return (result, .cloud(client.provider))
    }
}

/// Turns a capture into records.
nonisolated enum CaptureEngine {
    static func parse(_ input: String, context: CaptureContext, attempt: AIAttempt = .first) async throws -> CaptureOutcome {
        #if DEBUG
        if MockCapture.isEnabled {
            try await Task.sleep(for: .milliseconds(700))
            return CaptureOutcome(capture: MockCapture.capture(for: input, now: context.now), source: .onDevice)
        }
        #endif
        let instructions = context.instructions
        let plan = ThinkingPlanner.plan(for: .capture(input, isFollowUp: input.contains("\n补充："))).retried(attempt)
        var thinking: AIThinking?
        let (capture, source) = try await AIRouter.run(
            attempt: attempt,
            onDevice: {
                try await OnDeviceParser.parse(instructions: LocalAI.usesOpenModel ? context.compactInstructions : instructions,
                                               input: input, now: context.now, attempt: attempt)
            },
            isUsable: isUsable,
            isEmpty: { $0.items.isEmpty },
            cloud: { client in
                let (capture, level) = try await ThinkingPlanner.run(plan, client: client, isUsable: isUsable) {
                    try await $0.parse(instructions: instructions, input: input)
                }
                thinking = level
                return capture
            }
        )
        return CaptureOutcome(capture: withoutDestinationWords(capture), source: source, thinking: thinking)
    }

    /// A note's text without the words that only said where it goes (在装修这个笔记条目下加一条：…),
    /// whichever model wrote it: they picked the note, they aren't what's kept.
    static func withoutDestinationWords(_ capture: ParsedCapture) -> ParsedCapture {
        var result = capture
        for index in result.items.indices where result.items[index].type == "note" {
            result.items[index].note = NoteCommands.withoutCaptureCommand(result.items[index].note)
        }
        return result
    }

    /// Small models sometimes return nothing, records without a title, amounts that
    /// aren't numbers or dates that don't parse. Any of those sends the note to the cloud.
    static func isUsable(_ capture: ParsedCapture) -> Bool {
        guard !capture.items.isEmpty else { return false }
        for item in capture.items {
            guard CaptureSchema.itemTypes.contains(item.type), !item.title.trimmed.isEmpty else { return false }
            if ["expense", "income", "transfer", "receivable", "payable"].contains(item.type), Decimal(userInput: item.amount) == nil {
                return false
            }
            if item.type == "note", item.note.trimmed.isEmpty {
                return false
            }
            if !item.date.isEmpty, DraftParsing.date(item.date, time: item.time) == nil {
                return false
            }
        }
        return true
    }
}

nonisolated enum DraftParsing {
    /// "2026-10-15" (+ optional "18:30") in the current time zone.
    static func date(_ day: String, time: String = "", calendar: Calendar = .current) -> Date? {
        let dayParts = day.split(separator: "-").compactMap { Int($0) }
        guard dayParts.count == 3 else { return nil }
        var components = DateComponents(year: dayParts[0], month: dayParts[1], day: dayParts[2])
        let timeParts = time.split(separator: ":").compactMap { Int($0) }
        if timeParts.count >= 2 {
            components.hour = timeParts[0]
            components.minute = timeParts[1]
        }
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == dayParts[2]
        else { return nil }
        return date
    }

    /// Finds the closest name: exact, then one containing the other.
    static func bestMatch<T>(_ name: String, in items: [T], name keyPath: (T) -> String) -> T? {
        let target = name.trimmed.lowercased()
        guard !target.isEmpty else { return nil }
        if let exact = items.first(where: { keyPath($0).lowercased() == target }) { return exact }
        return items.first { item in
            let candidate = keyPath(item).lowercased()
            return !candidate.isEmpty && (candidate.contains(target) || target.contains(candidate))
        }
    }
}
