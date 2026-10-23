import SwiftUI

nonisolated enum TaskPriority: Int, CaseIterable, Identifiable, Codable {
    case none = 0, low, medium, high

    var id: Int { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .none: "无"
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        }
    }

    /// Exclamation marks shown next to a task, like Reminders.
    var marks: String { String(repeating: "!", count: rawValue) }
}

nonisolated enum EntryKind: String, CaseIterable, Identifiable, Codable {
    case expense, income, transfer

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .expense: "支出"
        case .income: "收入"
        case .transfer: "转账"
        }
    }

    var categoryKind: CategoryKind? {
        switch self {
        case .expense: .expense
        case .income: .income
        case .transfer: nil
        }
    }
}

nonisolated enum EntrySource: String, Codable {
    case manual, ai, bill
    /// Brought in from another app's CSV export.
    case imported
    /// Recorded when money owed was received or paid (应收应付).
    case outstanding
}

nonisolated enum CategoryKind: String, CaseIterable, Identifiable, Codable {
    case expense, income

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .expense: "支出"
        case .income: "收入"
        }
    }
}

nonisolated enum AccountKind: String, CaseIterable, Identifiable, Codable {
    case cash, debitCard, creditCard, eWallet, investment, other

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .cash: "现金"
        case .debitCard: "储蓄卡"
        case .creditCard: "信用卡"
        case .eWallet: "电子钱包"
        case .investment: "投资账户"
        case .other: "其他"
        }
    }

    var symbol: String {
        switch self {
        case .cash: "banknote"
        case .debitCard: "creditcard"
        case .creditCard: "creditcard.fill"
        case .eWallet: "iphone.gen3"
        case .investment: "chart.line.uptrend.xyaxis"
        case .other: "wallet.bifold"
        }
    }
}

nonisolated enum BillKind: String, CaseIterable, Identifiable, Codable {
    case creditCard, rent, utilities, loan, subscription, insurance, phone, other

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .creditCard: "信用卡"
        case .rent: "房租"
        case .utilities: "水电燃气"
        case .loan: "贷款"
        case .subscription: "订阅会员"
        case .insurance: "保险"
        case .phone: "通讯"
        case .other: "其他"
        }
    }

    var symbol: String {
        switch self {
        case .creditCard: "creditcard"
        case .rent: "house"
        case .utilities: "bolt"
        case .loan: "building.columns"
        case .subscription: "arrow.triangle.2.circlepath"
        case .insurance: "shield.lefthalf.filled"
        case .phone: "phone"
        case .other: "doc.text"
        }
    }
}

nonisolated enum ExpiryKind: String, CaseIterable, Identifiable, Codable {
    case document, insurance, contract, warranty, membership, other

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .document: "证件"
        case .insurance: "保险"
        case .contract: "合同"
        case .warranty: "保修"
        case .membership: "会员"
        case .other: "其他"
        }
    }

    var symbol: String {
        switch self {
        case .document: "person.text.rectangle"
        case .insurance: "shield.lefthalf.filled"
        case .contract: "doc.text"
        case .warranty: "wrench.and.screwdriver"
        case .membership: "star.circle"
        case .other: "calendar.badge.exclamationmark"
        }
    }

    /// Documents take months to renew, so they get an early first warning.
    var defaultReminderRules: [ReminderRule] {
        switch self {
        case .document: [90, 30, 7].map { ReminderRule(daysBefore: $0) }
        default: [30, 7, 0].map { ReminderRule(daysBefore: $0) }
        }
    }
}
