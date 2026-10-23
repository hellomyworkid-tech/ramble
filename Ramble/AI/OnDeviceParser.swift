import Foundation
import FoundationModels

nonisolated enum OnDeviceStatus: Equatable {
    case available, deviceNotEligible, notEnabled, notReady, unsupportedLanguage, unknown
    /// Open models: not downloaded yet, the system is older than iOS 27, or the phone lacks memory.
    case modelNotDownloaded, needsNewerSystem, notEnoughMemory

    var isAvailable: Bool { self == .available }

    var message: String {
        switch self {
        case .available: String(localized: "可用")
        case .deviceNotEligible: String(localized: "这台设备不支持 Apple Intelligence")
        case .notEnabled: String(localized: "请在系统设置中打开 Apple Intelligence")
        case .notReady: String(localized: "本机模型还在下载，稍后可用")
        case .unsupportedLanguage: String(localized: "本机模型暂不支持当前语言")
        case .unknown: String(localized: "本机模型暂时不可用")
        case .modelNotDownloaded: String(localized: "开源模型还没下载")
        case .needsNewerSystem: String(localized: "开源模型需要 iOS 27 或更新的系统")
        case .notEnoughMemory: String(localized: "这台设备的内存不够运行这个模型，可以换小一点的")
        }
    }
}

/// Apple's on-device model: free, offline and private, but small. Used first in
/// automatic mode; the capture engine checks its result before trusting it.
nonisolated enum OnDeviceParser {
    static var status: OnDeviceStatus {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.supportsLocale(Locale.current) ? .available : .unsupportedLanguage
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .notEnabled
        case .unavailable(.modelNotReady):
            return .notReady
        @unknown default:
            return .unknown
        }
    }

    static func parse(instructions: String, input: String, now: Date = .now, attempt: AIAttempt = .first) async throws -> ParsedCapture {
        if LocalAI.usesOpenModel {
            let session = LocalAI.makeSession(instructions: instructions + OpenCapture.examples)
            let response = try await session.respond(to: input, generating: OpenCapture.self,
                                                     options: LocalAI.captureOptions(for: input, attempt: attempt))
            return response.content.parsed(input: input, now: now)
        }
        let session = LocalAI.makeSession(instructions: instructions)
        let response = try await session.respond(to: input, generating: OnDeviceCapture.self,
                                                 options: LocalAI.captureOptions(for: input, attempt: attempt))
        var capture = response.content.parsed
        for (index, item) in response.content.items.enumerated() where capture.items.indices.contains(index) {
            // Small models leave some 嗯 and 然后那个 in; tidy what they missed.
            capture.items[index].note = FillerCleaner.clean(capture.items[index].note)
            capture.items[index].title = FillerCleaner.clean(capture.items[index].title)
            // They copy time words well but count days badly: work the date out here, from the
            // time words or else the item's own text.
            if let spoken = [item.when, item.note, item.title].lazy.compactMap({ SpokenDate.resolve($0, now: now) }).first {
                capture.items[index].apply(spoken)
            }
        }
        return capture
    }
}

@Generable
nonisolated struct OnDeviceCapture {
    @Guide(description: "Every record mentioned, in the order mentioned.")
    var items: [OnDeviceItem]
    @Guide(description: "Exact substrings of the note that are filler words, hesitations or abandoned self-corrections.")
    var fillerPhrases: [String]
    @Guide(description: "One short question in the note's language resolving uncertain amounts or dates, or empty.")
    var followUpQuestion: String

    var parsed: ParsedCapture {
        ParsedCapture(items: items.map(\.parsed), fillerPhrases: fillerPhrases, followUpQuestion: followUpQuestion)
    }
}

@Generable
nonisolated struct OnDeviceItem {
    @Guide(description: "Record type.", .anyOf(CaptureSchema.localItemTypes))
    var type: String
    @Guide(description: "Short name in the note's language, e.g. 午餐, 信用卡还款, 护照.")
    var title: String
    @Guide(description: "Plain decimal number such as 35 or 2180, or empty.")
    var amount: String
    @Guide(description: "True when the amount was vague and estimated.")
    var amountIsApproximate: Bool
    @Guide(description: "ISO 4217 code when a currency is named, else empty.")
    var currency: String
    @Guide(description: "For money: the closest category from the provided list. Empty otherwise.")
    var category: String
    @Guide(description: "An account name from the provided list, or empty.")
    var account: String
    @Guide(description: "Transfers: receiving account. Credit-card bills: the card being repaid. Else empty.")
    var toAccount: String
    @Guide(description: "The time words exactly as said, e.g. 下周三, 明天下午三点, 三个月以后, 月底前, 15号. Empty if none.")
    var when: String
    @Guide(description: "YYYY-MM-DD, or empty.")
    var date: String
    @Guide(description: "HH:mm 24-hour when a clock time is stated, else empty.")
    var time: String
    @Guide(description: "True when only the month is known.")
    var dateIsApproximate: Bool
    @Guide(description: "How it repeats.", .anyOf(["none", "daily", "weekly", "monthly", "yearly"]))
    var repeatFrequency: String
    @Guide(description: "Monthly only: day of month, -1 for the last day, else 0.")
    var repeatMonthDay: Int
    @Guide(description: "Days before the date to remind; 0 = on the day.")
    var reminderDaysBefore: [Int]
    @Guide(description: "Task priority.", .anyOf(["none", "low", "medium", "high"]))
    var priority: String
    @Guide(description: "Bills only.", .anyOf(["none"] + BillKind.allCases.map(\.rawValue)))
    var billKind: String
    @Guide(description: "Expiry items only.", .anyOf(["none"] + ExpiryKind.allCases.map(\.rawValue)))
    var expiryKind: String
    @Guide(description: "Notes: the content to keep, tidied, every fact kept. Else empty.")
    var note: String
    @Guide(description: "Fields that were guessed: title, amount, date, category or account.")
    var uncertainFields: [String]

    var parsed: ParsedItem {
        var item = ParsedItem()
        item.type = type
        item.title = title
        item.amount = amount
        item.amountIsApproximate = amountIsApproximate
        item.currency = currency
        item.category = category
        item.account = account
        item.toAccount = toAccount
        item.date = date
        item.time = time
        item.dateIsApproximate = dateIsApproximate
        item.repeatFrequency = repeatFrequency
        item.repeatMonthDay = repeatMonthDay
        item.reminderDaysBefore = reminderDaysBefore
        item.priority = priority
        item.billKind = billKind
        item.expiryKind = expiryKind
        item.note = note
        item.uncertainFields = uncertainFields
        return item
    }
}
