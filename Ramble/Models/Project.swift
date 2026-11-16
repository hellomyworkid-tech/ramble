import Foundation
import SwiftData

/// One matter the money goes on, across categories: 瓷砖 is 居住 and 灯具 is 购物, and both are 装修.
/// An entry belongs to at most one, and a note can follow one to show what it has cost so far.
@Model
final class Project {
    var name: String = ""
    /// Finished projects keep their totals but leave the pickers.
    var isFinished: Bool = false
    var createdAt: Date = Date.now

    @Relationship(deleteRule: .nullify, inverse: \LedgerEntry.project)
    var entries: [LedgerEntry]? = []
    @Relationship(deleteRule: .nullify, inverse: \Note.project)
    var notes: [Note]? = []

    init(name: String) {
        self.name = name
        self.createdAt = .now
    }

    /// Spent on it so far, in the base currency at each entry's own rate, less refunds.
    var spent: Decimal {
        (entries ?? []).filter { $0.kind == .expense }.reduce(0) { $0 + $1.baseAmount }
    }

    /// The project a record belongs to, going by what it says: 「装修买瓷砖」 is 装修. The longest name
    /// wins, so 「厨房装修」 isn't taken for 「装修」.
    static func named(in text: String, among projects: [Project]) -> Project? {
        projects
            .filter { !$0.name.trimmed.isEmpty && text.localizedCaseInsensitiveContains($0.name.trimmed) }
            .max { $0.name.count < $1.name.count }
    }
}
