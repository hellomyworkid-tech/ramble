import Foundation

/// Removes spoken filler the on-device models tend to leave in: hesitation sounds anywhere,
/// and 那个 / 就是 / 然后 only where they're plainly filler (at the start of a clause and
/// followed by a pause or another filler), so 那个人, 就是这个 and 然后去吃饭 stay.
nonisolated enum FillerCleaner {
    private static let clauseStart = #"(^|[，,。.！!？?；;、…\s])"#
    /// Pure hesitation sounds: never words in their own right.
    private static let sounds = "嗯+|呃+|唔+|额+(?=[，,。…\\s]|$)|啊+(?=[，,…\\s])|哦+(?=[，,…\\s])"
    /// Filler words that only count as filler before a pause, more filler, or a word that can't
    /// follow them as real words: 那个今天 and 那个我 aren't phrases, so 那个 there is filler.
    private static let softWords = "那个|这个|就是说|就是|然后|反正|怎么说呢"
    private static let pauseOrFiller = "(?=[，,、…\\s]|嗯|呃|唔|额|那个|就是|然后|我|你|他|她|咱|今天|明天|昨天|后天|前天|下周|上周|这周|刚才|现在|其实)"

    static func clean(_ text: String) -> String {
        var result = text
        // A run of fillers at the start of a clause, with the commas and spaces between them.
        let leading = clauseStart + "((?:(?:" + sounds + ")|(?:(?:" + softWords + ")" + pauseOrFiller + "))[，,、…\\s]*)+"
        result = replace(leading, in: result, with: "$1")
        // 那个 / 就是 right before a pause, anywhere: 还有就是，校服钱 → 还有，校服钱.
        result = replace("(?:那个|就是说|就是)(?=[，,、…])", in: result, with: "")
        // Hesitation sounds in the middle of a clause.
        result = replace("(?:" + sounds + ")[，,、…]?", in: result, with: "")
        // English hesitations.
        result = replace(#"(?i)\b(?:um+|uh+|erm+|uhm+|hmm+)\b[,]?\s*"#, in: result, with: "")
        // Tidy what's left: doubled commas, a comma before a full stop, a comma or space opening a clause.
        result = replace("[，,]{2,}", in: result, with: "，")
        result = replace("[，,、]+([。！？.!?])", in: result, with: "$1")
        result = replace(#"(^|[。！？.!?\n])[\s，,、]+"#, in: result, with: "$1")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `text` still has obvious filler a good result wouldn't.
    static func hasFiller(_ text: String) -> Bool {
        clean(text) != text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
