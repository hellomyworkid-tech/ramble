import Foundation

/// Spots money that's owed rather than spent or received, which models tend to file as income
/// or expense: 「张三还欠我两千」「借给小王五千」 are 应收, 「还欠装修师傅三千工钱」「跟李四借了两千」 应付.
/// Also picks out who owes whom.
nonisolated enum OutstandingCues {
    static func direction(in text: String) -> OutstandingDirection? {
        if text.firstMatch(of: receivable) != nil { return .receivable }
        if text.firstMatch(of: payable) != nil { return .payable }
        // Money that has already moved: 「收回欠款」「还清了」.
        if text.firstMatch(of: #/收回|收到|还清|结清|付清|还了/#) != nil { return nil }
        // 「客户还欠五万」 is owed to the person; 「还欠师傅三千」, with nobody before 欠, is owed by them.
        // Not 欠费 (an overdue phone bill), 欠条, 欠佳, 欠缺 or 亏欠.
        let owes = text.indices.first { index in
            guard text[index] == "欠" else { return false }
            let next = text.index(after: index)
            if next < text.endIndex, "费条佳缺".contains(text[next]) { return false }
            return index == text.startIndex || text[text.index(before: index)] != "亏"
        }
        if let owes {
            var before = String(text[..<owes])
            for word in ["一共", "总共", "还", "又", "都"] where before.hasSuffix(word) { before.removeLast(word.count) }
            before = before.trimmingCharacters(in: .whitespaces)
            let subject = before.split(whereSeparator: { "，,。".contains($0) }).last.map(String.init) ?? ""
            let lenders = ["信用卡", "花呗", "白条", "借呗", "贷款", "银行", "房贷", "车贷"]
            if subject.isEmpty || subject.hasSuffix("我") || lenders.contains(where: subject.contains) { return .payable }
            return .receivable
        }
        return nil
    }

    private static let receivable = #/欠我|没(?:还|给|转|打)(?:给)?我|还没收到|没收到(?:钱|款)|应收|待收|借给|帮.{1,6}?垫|垫(?:付|了)|该给我|要回来/#
    private static let payable = #/我欠|还没(?:付|给|转|结)|没付|应付|待付|尾款没|(?:跟|向|找)[^，,。]{1,6}?借|借了/#

    /// Who owes or is owed, as said: 「张三还欠我两千」 → 张三, 「还欠师傅三千」 → 师傅. Empty when unclear.
    static func counterparty(in text: String, direction: OutstandingDirection) -> String {
        let amount = #"(?:[0-9]|[一二两三四五六七八九十几][十百千万块]|[十百千万])"#
        let patterns = direction == .receivable
            ? [#"([^，,。\s]{1,8}?)(?:还|又|一直|都)?欠我"#,
               #"借给([^，,。\s]{1,6}?)了?"# + amount,
               #"帮([^，,。\s]{1,6}?)垫"#,
               #"([^，,。\s]{1,8}?)(?:还|一直|都)?没(?:还|给|转|打)(?:给)?我"#,
               #"([^，,。\s]{1,8}?)(?:还|又|一共|总共)欠"#]
            : [#"欠([^，,。\s]{1,6}?)的?"# + amount,
               #"(?:跟|向|找)([^，,。\s]{1,6}?)借"#,
               #"(?:付|给|转|结)给([^，,。\s]{1,6}?)(?:的|"# + amount + ")"]
        for pattern in patterns {
            guard let regex = try? Regex(pattern), let match = text.firstMatch(of: regex),
                  let captured = match.output[1].substring else { continue }
            var name = String(captured)
            for filler in ["然后", "那个", "就是", "还有", "另外", "对了", "还"] where name.hasPrefix(filler) {
                name.removeFirst(filler.count)
            }
            name = name.trimmingCharacters(in: .whitespaces)
            if name.count >= 1, !["我", "他", "她", "钱", "人"].contains(name), !name.contains("钱") { return name }
        }
        return ""
    }
}
