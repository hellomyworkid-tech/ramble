import Foundation
import SwiftData

/// The ledger as a spreadsheet, and entries brought in from other apps' CSV exports
/// (bookkeeping apps, WeChat Pay and Alipay statements).
enum LedgerCSV {
    // MARK: Export

    /// In the app's language; the importer knows both the Chinese and the English names.
    static var exportHeader: [String] {
        [String(localized: "日期"), String(localized: "类型"), String(localized: "金额"), String(localized: "币种"),
         String(localized: "分类"), String(localized: "子分类"), String(localized: "账户"), String(localized: "转入账户"),
         String(localized: "备注"), String(localized: "来源")]
    }

    /// UTF-8 with a byte-order mark, so Excel and Numbers show the Chinese properly.
    static func export(_ entries: [LedgerEntry]) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var rows = [exportHeader]
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            let category = entry.category
            let topCategory = category?.parent ?? category
            rows.append([
                formatter.string(from: entry.date),
                String(localized: entry.kind.title),
                "\(entry.amount)",
                entry.currencyCode,
                topCategory?.name ?? "",
                category?.parent != nil ? category?.name ?? "" : "",
                entry.account?.name ?? "",
                entry.toAccount?.name ?? "",
                entry.note,
                sourceTitle(entry.sourceRaw),
            ])
        }
        let text = rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        return Data("\u{FEFF}".utf8) + Data(text.utf8)
    }

    private static func sourceTitle(_ raw: String) -> String {
        switch EntrySource(rawValue: raw) {
        case .ai: String(localized: "AI")
        case .bill: String(localized: "账单")
        case .imported: String(localized: "导入")
        case .outstanding: String(localized: "应收应付")
        default: String(localized: "手动")
        }
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { ",\"\r\n".contains($0) }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func fileName(now: Date = .now) -> String {
        String(localized: "随口记账目 \(now.formatted(.iso8601.year().month().day()))")
    }

    // MARK: Reading

    /// UTF-8 first, then the GB18030 that Alipay and older Windows tools write, then UTF-16.
    static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) {
            return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let text = String(data: data, encoding: gb18030) { return text }
        return String(data: data, encoding: .utf16)
    }

    /// RFC 4180 rows: quoted fields may hold commas, quotes ("") and line breaks. Tab-separated
    /// files are recognised by their first lines.
    static func rows(_ text: String) -> [[String]] {
        let sample = text.prefix(2000)
        let delimiter: Character = sample.filter { $0 == "\t" }.count > sample.filter { $0 == "," }.count ? "\t" : ","
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = Array(text).makeIterator()
        var pending: Character?
        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty:
                inQuotes = true
            case delimiter:
                row.append(field)
                field = ""
            case "\r\n", "\n", "\r":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            default:
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows.map { $0.map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { $0.contains { !$0.isEmpty } }
    }

    // MARK: Import

    /// What a column holds.
    enum Field: String, CaseIterable, Identifiable {
        case date, amount, kind, category, subcategory, account, counterparty, item, note, currency

        var id: String { rawValue }

        var title: String {
            switch self {
            case .date: String(localized: "日期")
            case .amount: String(localized: "金额")
            case .kind: String(localized: "收支类型")
            case .category: String(localized: "分类")
            case .subcategory: String(localized: "子分类")
            case .account: String(localized: "账户")
            case .note: String(localized: "备注")
            case .counterparty: String(localized: "交易对方")
            case .item: String(localized: "商品 / 说明")
            case .currency: String(localized: "币种")
            }
        }

        /// Header words that give the column away, most specific first.
        var hints: [String] {
            switch self {
            case .date: ["交易时间", "记账时间", "日期", "时间", "date", "time"]
            case .amount: ["金额(元)", "金额（元）", "金额", "amount", "money"]
            case .kind: ["收/支", "收支类型", "收支", "交易类型", "类型", "type"]
            case .category: ["一级分类", "交易分类", "分类", "类别", "category"]
            case .subcategory: ["二级分类", "子分类", "subcategory"]
            case .account: ["账户1", "账户", "收/付款方式", "支付方式", "account"]
            case .note: ["备注", "note", "memo"]
            case .counterparty: ["交易对方", "对方", "商户", "payee"]
            case .item: ["商品说明", "商品名称", "商品", "说明", "摘要", "description"]
            case .currency: ["币种", "货币", "currency"]
            }
        }
    }

    /// A file's rows split into the header and the data under it.
    struct Table {
        var header: [String]
        var rows: [[String]]

        /// Statements open with lines of account details; the header is the first row that names
        /// both a date and an amount column.
        init?(_ allRows: [[String]]) {
            let headerIndex = allRows.prefix(40).firstIndex { row in
                let cells = row.map { $0.lowercased() }
                let hasDate = cells.contains { cell in Field.date.hints.contains { cell.contains($0) } }
                let hasAmount = cells.contains { cell in Field.amount.hints.contains { cell.contains($0) } }
                return hasDate && hasAmount && row.filter { !$0.isEmpty }.count >= 2
            }
            guard let headerIndex else { return nil }
            header = allRows[headerIndex]
            rows = Array(allRows[(headerIndex + 1)...]).filter { $0.count >= 2 }
        }

        /// The column each field most likely is, by header; a column is used once.
        func guessedMapping() -> [Field: Int] {
            var mapping: [Field: Int] = [:]
            var used = Set<Int>()
            let cells = header.map { $0.lowercased().replacingOccurrences(of: " ", with: "") }
            // Subcategory and the descriptive columns first, so "二级分类" isn't taken as the category.
            for field in [Field.subcategory, .counterparty, .item, .date, .amount, .kind, .category, .account, .note, .currency] {
                for hint in field.hints {
                    if let index = cells.indices.first(where: { !used.contains($0) && (cells[$0] == hint || cells[$0].contains(hint)) }) {
                        mapping[field] = index
                        used.insert(index)
                        break
                    }
                }
            }
            return mapping
        }
    }

    /// One row read with the chosen mapping.
    struct Row: Equatable {
        var date: Date
        var kind: EntryKind
        var amount: Decimal
        var currency: String?
        var category: String
        var subcategory: String
        var account: String
        var note: String
    }

    enum RowProblem: Error, Equatable {
        /// "不计收支", refunds marked neutral, empty lines.
        case skipped
        case badDate
        case badAmount
    }

    /// Reads one row. `signedAmounts`: the file has no type column and marks money out with a
    /// minus sign, so positive amounts are income.
    static func read(_ cells: [String], mapping: [Field: Int], signedAmounts: Bool = false) -> Result<Row, RowProblem> {
        func cell(_ field: Field) -> String {
            guard let index = mapping[field], cells.indices.contains(index) else { return "" }
            return cells[index].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let date = parseDate(cell(.date)) else { return .failure(cell(.date).isEmpty ? .skipped : .badDate) }
        guard let signed = parseAmount(cell(.amount)) else { return .failure(cell(.amount).isEmpty ? .skipped : .badAmount) }

        let kind: EntryKind
        let kindText = cell(.kind)
        if mapping[.kind] != nil, !kindText.isEmpty {
            if ["不计收支", "转账", "transfer"].contains(where: { kindText.localizedCaseInsensitiveContains($0) }) || kindText == "/" {
                return .failure(.skipped)
            } else if ["收入", "income", "收款", "入账"].contains(where: { kindText.localizedCaseInsensitiveContains($0) }) {
                kind = .income
            } else {
                kind = .expense
            }
        } else {
            kind = signedAmounts && signed > 0 ? .income : .expense
        }
        let amount = abs(signed)
        guard amount > 0 else { return .failure(.skipped) }

        // "兰州拉面 · 牛肉面": who, what, then any remark; placeholders and repeats dropped.
        var parts: [String] = []
        for part in [cell(.counterparty), cell(.item), cell(.note)] where !part.isEmpty && part != "/" && part != "-" && !parts.contains(part) {
            parts.append(part)
        }
        let note = parts.joined(separator: " · ")
        return .success(Row(date: date, kind: kind, amount: amount, currency: cell(.currency).isEmpty ? nil : cell(.currency).uppercased(),
                            category: cell(.category), subcategory: cell(.subcategory), account: cell(.account), note: note))
    }

    /// Whether amounts carry their own sign: no type column, and some are negative.
    static func usesSignedAmounts(_ rows: [[String]], mapping: [Field: Int]) -> Bool {
        guard mapping[.kind] == nil, let index = mapping[.amount] else { return false }
        return rows.contains { $0.indices.contains(index) && (parseAmount($0[index]) ?? 0) < 0 }
    }

    /// "¥1,234.50", "-35", "（35.00）", "35元".
    static func parseAmount(_ text: String) -> Decimal? {
        var cleaned = text.replacingOccurrences(of: #"[¥￥,，\s元]|CNY|RMB"#, with: "", options: .regularExpression)
        var negative = false
        if cleaned.hasPrefix("(") || cleaned.hasPrefix("（") {
            negative = true
            cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "()（）"))
        }
        if cleaned.hasPrefix("+") { cleaned.removeFirst() }
        if cleaned.hasPrefix("-") || cleaned.hasPrefix("−") {
            negative.toggle()
            cleaned.removeFirst()
        }
        guard !cleaned.isEmpty, cleaned.allSatisfy({ $0.isNumber || $0 == "." }),
              let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return negative ? -value : value
    }

    private static let dateFormats = [
        "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy/M/d HH:mm:ss", "yyyy/M/d H:mm", "yyyy/M/d",
        "yyyy.M.d HH:mm", "yyyy.M.d", "yyyy年M月d日 HH:mm", "yyyy年M月d日", "M/d/yyyy H:mm", "M/d/yyyy", "yyyyMMdd",
    ]

    private static let dateFormatters: [DateFormatter] = dateFormats.map {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = $0
        formatter.isLenient = false
        return formatter
    }

    static func parseDate(_ text: String) -> Date? {
        let trimmed = text.replacingOccurrences(of: "\t", with: "").trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        for formatter in dateFormatters {
            if let date = formatter.date(from: trimmed) { return date }
        }
        // Excel serial dates (days since 1899-12-30).
        if let serial = Double(trimmed), serial > 20_000, serial < 80_000 {
            return Date(timeIntervalSince1970: (serial - 25_569) * 86_400 - Double(TimeZone.current.secondsFromGMT()))
        }
        return nil
    }

    /// How rows become entries.
    struct ImportOptions {
        var createsMissingCategories = true
        var skipsDuplicates = true
    }

    struct ImportResult: Equatable {
        var imported = 0
        var duplicates = 0
        var newCategories: [String] = []
    }

    /// Adds the rows as entries. Categories and accounts are matched by name; a row whose date,
    /// amount, type and note match an existing entry is taken as already there.
    static func importRows(_ rows: [Row], options: ImportOptions, into context: ModelContext) throws -> ImportResult {
        var result = ImportResult()
        let categories = try context.fetch(FetchDescriptor<LedgerCategory>())
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let base = LedgerSummary.baseCurrency

        var existing = Set<String>()
        if options.skipsDuplicates, let first = rows.map(\.date).min(), let last = rows.map(\.date).max() {
            let start = first.addingTimeInterval(-60), end = last.addingTimeInterval(60)
            let entries = try context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.date >= start && $0.date <= end }))
            existing = Set(entries.map { key($0.kind, $0.amount, $0.date, $0.note) })
        }

        var created: [String: LedgerCategory] = [:]
        func category(for row: Row) -> LedgerCategory? {
            let kind: CategoryKind = row.kind == .income ? .income : .expense
            let sameKind = categories.filter { $0.kind == kind } + created.values.filter { $0.kind == kind }
            let other = sameKind.first { $0.seedKey == (kind == .income ? "other-income" : "other-expense") }
            let guessed = guessedSeedKey(for: row.category + " " + row.subcategory + " " + row.note, kind: kind)
                .flatMap { key in sameKind.first { $0.seedKey == key } }
            let topName = row.category.isEmpty ? row.subcategory : row.category
            guard !topName.isEmpty else { return guessed ?? other }
            if !row.subcategory.isEmpty, !row.category.isEmpty {
                if let child = sameKind.first(where: { $0.name == row.subcategory && $0.parent?.name == topName }) { return child }
                if let child = sameKind.first(where: { $0.name == row.subcategory }) { return child }
            }
            if let top = sameKind.first(where: { $0.parent == nil && $0.name == topName }) ?? sameKind.first(where: { $0.name == topName }) {
                return top
            }
            // "餐饮美食" is the 餐饮 the person already has.
            if let similar = sameKind.first(where: { $0.parent == nil && $0.name.count >= 2 && (topName.contains($0.name) || $0.name.contains(topName)) }) {
                return similar
            }
            if let guessed { return guessed }
            guard options.createsMissingCategories else { return other }
            let new = LedgerCategory(name: topName, kind: kind, symbol: "tag.fill", colorHex: "#8E8E93",
                                     sortOrder: (categories.map(\.sortOrder).max() ?? 0) + created.count + 1)
            context.insert(new)
            created[kind.rawValue + topName] = new
            result.newCategories.append(topName)
            return new
        }

        for row in rows {
            if options.skipsDuplicates {
                let rowKey = key(row.kind, row.amount, row.date, row.note)
                if existing.contains(rowKey) {
                    result.duplicates += 1
                    continue
                }
                existing.insert(rowKey)
            }
            let entry = LedgerEntry(kind: row.kind, amount: row.amount, currencyCode: row.currency ?? base,
                                    date: row.date, note: row.note, source: .imported)
            context.insert(entry)
            entry.category = category(for: row)
            entry.account = accounts.first { !row.account.isEmpty && $0.name == row.account }
            entry.applyCurrentRate()
            result.imported += 1
        }
        try context.save()
        return result
    }

    /// The built-in category a merchant or item most likely belongs to, for statements with no
    /// category of their own (WeChat Pay) or one the person doesn't have.
    /// The built-in category whose words cover the most of the text: 「铺地暖和买瓷砖」 is 居住
    /// (地暖, 瓷砖), and 「手机费」 is 通讯 rather than 购物 (手机). Ties go to the earlier category.
    static func guessedSeedKey(for text: String, kind: CategoryKind) -> String? {
        let table = kind == .income ? incomeKeywords : categoryKeywords
        var best: (key: String, score: Int)?
        for (key, words) in table {
            let score = words.filter { text.localizedCaseInsensitiveContains($0) }.reduce(0) { $0 + $1.count }
            if score > (best?.score ?? 0) { best = (key, score) }
        }
        return best?.key
    }

    static let incomeKeywords: [(String, [String])] = [
        ("salary", ["工资", "薪资", "薪水", "代发", "月薪"]),
        ("bonus", ["奖金", "年终", "绩效", "提成"]),
        ("investment", ["收益", "利息", "理财", "分红", "基金", "股息", "股票"]),
        ("other-income", ["报销", "退款", "退货", "稿费", "兼职", "货款", "项目款", "尾款", "卖了", "二手"]),
    ]

    /// Merchants and items by built-in expense category; also what questions like 「打车花了多少」 match.
    static let categoryKeywords: [(String, [String])] = [
        ("food", ["餐", "饭", "拉面", "面馆", "米线", "外卖", "饿了么", "咖啡", "奶茶", "瑞幸", "星巴克", "肯德基", "麦当劳",
                  "茶饮", "早点", "食堂", "烧烤", "火锅", "面包", "蛋糕", "美食", "喜茶", "蜜雪", "夜宵", "买菜", "蔬菜",
                  "菜市场", "水果", "零食", "饮料", "小吃", "甜品", "粮油"]),
        ("transport", ["滴滴", "打车", "出租", "地铁", "公交", "加油", "停车", "高速", "ETC", "单车", "哈啰", "交通", "油费",
                       "充电桩", "车费", "修车", "洗车", "保养", "过路费", "网约车"]),
        ("travel", ["12306", "铁路", "航空", "机票", "酒店", "携程", "飞猪", "旅行", "景区", "旅游", "民宿", "高铁", "火车票",
                    "动车", "签证"]),
        ("housing", ["房租", "物业", "水费", "电费", "燃气", "水电", "租金", "家居", "装修", "瓷砖", "地砖", "暖气", "地暖",
                     "供暖", "采暖", "建材", "水泥", "油漆", "涂料", "地板", "门窗", "窗帘", "灯具", "卫浴", "橱柜", "五金",
                     "家具", "家电", "沙发", "床垫", "空调", "冰箱", "洗衣机", "热水器", "维修", "修理", "搬家", "保洁",
                     "家政", "房贷", "月供"]),
        ("health", ["医院", "药房", "药店", "大药", "诊所", "体检", "医疗", "门诊", "看病", "挂号", "买药", "药费", "看牙",
                    "牙科", "洗牙", "补牙", "眼科", "住院", "手术", "化验", "复查"]),
        ("telecom", ["话费", "流量", "宽带", "移动", "联通", "电信", "手机费", "月租"]),
        ("fun", ["电影", "影城", "游戏", "KTV", "会员", "视频", "音乐", "健身", "娱乐", "门票", "演唱会", "演出", "展览",
                 "剧本杀", "密室", "酒吧", "唱歌", "游乐"]),
        ("learning", ["书店", "课程", "培训", "教育", "学费", "图书", "买书", "教材", "辅导", "补习", "网课", "考试",
                      "报名费", "文具"]),
        ("social", ["红包", "礼物", "礼金", "份子", "转账", "请客", "送礼", "随礼", "压岁钱"]),
        ("shopping", ["淘宝", "天猫", "京东", "拼多多", "超市", "便利店", "商场", "购物", "百货", "盒马", "山姆", "衣服",
                      "裤子", "鞋", "化妆品", "护肤", "日用品", "纸巾", "洗发水", "牙膏", "数码", "耳机", "电脑", "手机",
                      "网购", "闲鱼"]),
    ]

    private static func key(_ kind: EntryKind, _ amount: Decimal, _ date: Date, _ note: String) -> String {
        "\(kind.rawValue)|\(amount)|\(Int(date.timeIntervalSince1970 / 60))|\(note)"
    }
}
