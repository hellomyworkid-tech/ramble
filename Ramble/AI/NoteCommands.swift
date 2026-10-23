import Foundation

/// Things said *to the app* inside a note: 「给这条标记一下重点」「划重点」. They aren't content, so
/// they're taken out of the text and carried out instead. Rules catch the usual ways of saying
/// it, on the phone and without AI; AI catches the rest through `markAsKeyPoint`.
nonisolated enum NoteCommands {
    struct Result: Equatable {
        var text: String
        var markAsKeyPoint: Bool
    }

    /// Asking for a mark: 「给本条标记一下重点」「把这条标为重点」「设为重要」「划个重点」「加个星标」.
    private static let commands: [Regex<Substring>] = [
        #/(?:请|帮我|麻烦)?(?:给|把|将)?(?:本条|这条|这一条|这段|这一段|本段|这个|这些|它)?(?:记录|内容|笔记)?(?:给我)?(?:标记|标注|标出来|标|设置|设|记|列|算)(?:一下|下)?(?:成|为|作)?(?:个|一个)?(?:重点|重要)(?:内容|事项|记录)?(?:吧|啊|哈|呀)?/#,
        #/(?:请|帮我)?划(?:个|一个|一下)?重点(?:吧|啊)?/#,
        #/(?:请|帮我)?(?:加|打|标)(?:个|一个|上)?(?:星标|五角星|星)(?:吧|啊)?/#,
        #/(?:这条|本条)(?:是)?重点(?:吧|啊)?/#,
    ]

    /// Saying it matters, as part of what's said: marked, but the words stay.
    private static let emphasis: [Regex<Substring>] = [
        #/(?:这条|这件事|这个事|这段)(?:很|非常|特别|超级)重要/#,
        #/(?:重要的事|划重点|敲黑板)/#,
    ]

    /// 「添加一个笔记」「记一下」at the start of a capture say where it goes, not what it says.
    private static let captureCommand = #/^(?:请|帮我|给我)?(?:(?:添加|新建|新增|建|写|加|记)(?:一下|下)?(?:一个|一条|个|条)?(?:新的)?(?:笔记|备忘录|备忘|记录)|记(?:一下|下))(?:吧)?[，,：:、\s]*(?:就是|然后|那个|这个|呃|嗯|啊)*[，,\s]*/#

    /// 「在装修这个笔记条目下加一条：」「往装修笔记里记一下，」「装修笔记加一条：」「记到装修里：」 say which note
    /// it goes in. The AI picks the note from them; they aren't part of what's kept. A verb has to be
    /// followed by 一下/一条 or punctuation, so 「在公司楼下记得买咖啡」「我的笔记写得很乱」 stay as they are.
    private static let leadingDestinations: [Regex<Substring>] = [
        // 在/往 + name + 笔记 (+ 里/下) + verb
        #/^(?:请|帮我|麻烦你?|给我)?(?:在|往|向|到|给)[^，,。：:\s]{1,12}?(?:这个|那个|这一个|的)?(?:笔记|备忘录|备忘|条目)+(?:里面|里头|里边|里|下面|下边|下|中|上)?(?:再)?(?:添加|新增|加|记|写|追加|补充|补)(?:(?:上)?(?:(?:一下|下)(?:一条|一个|一段|一句|条|个)?|一条|一个|一段|一句|条|个|点)(?:新的)?(?:记录|内容|笔记)?[：:，,\s]*|(?:上)?[：:，,\s]+)/#,
        // 在/往 + name + 里/下 + verb, without the word 笔记
        #/^(?:请|帮我|麻烦你?|给我)?(?:在|往|向|到)[^，,。：:\s]{1,12}?(?:这个|那个|的)?(?:里面|里头|里边|里|下面|下边|下|中|上)(?:再)?(?:添加|新增|加|记|写|追加|补充|补)(?:(?:上)?(?:(?:一下|下)(?:一条|一个|一段|一句|条|个)?|一条|一个|一段|一句|条|个|点)(?:新的)?(?:记录|内容|笔记)?[：:，,\s]*|(?:上)?[：:，,\s]+)/#,
        // name + 笔记 + verb
        #/^(?:请|帮我|麻烦你?|给我)?[^，,。：:\s]{1,12}?(?:这个|那个)?(?:笔记|备忘录|备忘|条目)+(?:里面|里头|里边|里|下面|下边|下|中|上)?(?:再)?(?:添加|新增|加|记|写|追加|补充|补)(?:(?:上)?(?:(?:一下|下)(?:一条|一个|一段|一句|条|个)?|一条|一个|一段|一句|条|个|点)(?:新的)?(?:记录|内容|笔记)?[：:，,\s]*|(?:上)?[：:，,\s]+)/#,
        // 记到/放进 + name (+ 笔记) + punctuation
        #/^(?:请|帮我|麻烦你?|给我)?(?:记到|记在|记进|放进|放到|放在|加到|加进|添加到|写到|写在|写进|存到|存进|归到)[^，,。：:\s]{1,12}?(?:这个|那个)?(?:笔记|备忘录|备忘|条目)*(?:里面|里|中|下面|下)?(?:去|吧)?[：:，,\s]+/#,
    ]

    /// The same said at the end: 「……，记到装修笔记里。」
    private static let trailingDestination = #/[，,。\s]*(?:请|帮我)?(?:记到|记在|记进|放进|放到|放在|加到|加进|添加到|写到|写进|存到|存进|归到)[^，,。：:\s]{1,12}?(?:这个|那个)?(?:笔记|备忘录|备忘|条目)+(?:里面|里|中|下面|下)?(?:去|吧)?[。.!！]?$/#

    static func withoutCaptureCommand(_ text: String) -> String {
        var rest = text
        if let match = rest.firstMatch(of: captureCommand), !match.output.isEmpty {
            rest = String(rest[match.range.upperBound...])
        }
        for pattern in leadingDestinations {
            if let match = rest.firstMatch(of: pattern), !match.output.isEmpty {
                rest = String(rest[match.range.upperBound...])
                break
            }
        }
        if let match = rest.firstMatch(of: trailingDestination) {
            rest = String(rest[..<match.range.lowerBound])
            if let last = rest.last, !"。！？!?…".contains(last) { rest += "。" }
        }
        rest = rest.trimmingCharacters(in: .whitespaces)
        return rest.count >= 2 ? rest : text
    }

    static func extract(_ text: String) -> Result {
        var result = text
        var marked = false
        for pattern in commands {
            while let match = result.firstMatch(of: pattern), !match.output.isEmpty {
                result.removeSubrange(match.range)
                marked = true
            }
        }
        if !marked {
            marked = emphasis.contains { text.firstMatch(of: $0) != nil }
        }
        guard marked else { return Result(text: text, markAsKeyPoint: false) }
        return Result(text: tidyPunctuation(result), markAsKeyPoint: true)
    }

    /// What's left after taking a phrase out: no doubled or dangling commas.
    private static func tidyPunctuation(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: #"[，,、]\s*([。！？!?；;])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([，,。；;、])\s*[，,、]+"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"^[\s，,。；;、]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A sentence that ended in a comma once the command was gone gets its full stop back.
        var droppedComma = false
        while let last = result.last, "，,、；;".contains(last) {
            result.removeLast()
            droppedComma = true
        }
        if droppedComma, let last = result.last, !"。！？!?…".contains(last) {
            result += "。"
        }
        return result
    }
}
