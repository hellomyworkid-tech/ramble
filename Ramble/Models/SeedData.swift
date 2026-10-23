import Foundation
import SwiftData
import UIKit

enum SeedData {
    private struct CategorySeed {
        let key: String
        let name: String.LocalizationValue
        let symbol: String
        let color: String
    }

    private static let expenseCategories: [CategorySeed] = [
        .init(key: "food", name: "餐饮", symbol: "fork.knife", color: "#D9480F"),
        .init(key: "transport", name: "交通", symbol: "tram.fill", color: "#0A66D8"),
        .init(key: "shopping", name: "购物", symbol: "bag.fill", color: "#C2185B"),
        .init(key: "housing", name: "居住", symbol: "house.fill", color: "#A16207"),
        .init(key: "fun", name: "娱乐", symbol: "gamecontroller.fill", color: "#8944AB"),
        .init(key: "health", name: "医疗", symbol: "cross.case.fill", color: "#D70015"),
        .init(key: "learning", name: "学习", symbol: "book.fill", color: "#4F46E5"),
        .init(key: "telecom", name: "通讯", symbol: "phone.fill", color: "#0E7C86"),
        .init(key: "social", name: "人情", symbol: "gift.fill", color: "#C2570C"),
        .init(key: "travel", name: "旅行", symbol: "airplane", color: "#248A3D"),
        .init(key: "other-expense", name: "其他", symbol: "ellipsis.circle.fill", color: "#6E6E73"),
    ]

    private static let incomeCategories: [CategorySeed] = [
        .init(key: "salary", name: "工资", symbol: "briefcase.fill", color: "#248A3D"),
        .init(key: "bonus", name: "奖金", symbol: "star.fill", color: "#A16207"),
        .init(key: "investment", name: "理财", symbol: "chart.line.uptrend.xyaxis", color: "#0E7C86"),
        .init(key: "other-income", name: "其他收入", symbol: "plus.circle.fill", color: "#6E6E73"),
    ]

    static func seedDefaultsIfNeeded(_ context: ModelContext) {
        let existing = (try? context.fetchCount(FetchDescriptor<LedgerCategory>())) ?? 0
        guard existing == 0 else { return }

        for (index, seed) in expenseCategories.enumerated() {
            context.insert(LedgerCategory(name: String(localized: seed.name), kind: .expense, symbol: seed.symbol, colorHex: seed.color, sortOrder: index, seedKey: seed.key))
        }
        for (index, seed) in incomeCategories.enumerated() {
            context.insert(LedgerCategory(name: String(localized: seed.name), kind: .income, symbol: seed.symbol, colorHex: seed.color, sortOrder: index, seedKey: seed.key))
        }

        let currency = UserDefaults.standard.string(forKey: AppSettings.baseCurrencyKey) ?? AppSettings.defaultBaseCurrency
        for (index, seed) in defaultAccounts.enumerated() {
            let account = Account(name: String(localized: seed.name), kind: seed.kind, currencyCode: currency, sortOrder: index)
            account.seedKey = seed.key
            context.insert(account)
        }
        try? context.save()
    }

    private static let defaultAccounts: [(key: String, name: String.LocalizationValue, kind: AccountKind)] = [
        ("cash", "现金", .cash), ("debit-card", "储蓄卡", .debitCard), ("credit-card", "信用卡", .creditCard), ("e-wallet", "电子钱包", .eWallet),
    ]

    /// Accounts seeded before they carried a key get theirs, so they can be matched with another device's copies.
    static func backfillAccountSeedKeys(_ context: ModelContext) {
        let accounts = (try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        var changed = false
        for seed in defaultAccounts where !accounts.contains(where: { $0.seedKey == seed.key }) {
            let name = String(localized: seed.name)
            if let account = accounts.first(where: { $0.seedKey == nil && $0.name == name && $0.kind == seed.kind }) {
                account.seedKey = seed.key
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    #if DEBUG
    /// Fills the store with the scenario from the design mockups so every screen has content.
    static func loadSampleData(_ context: ModelContext, now: Date = .now) {
        seedDefaultsIfNeeded(context)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int, _ hour: Int = 9, _ minute: Int = 0) -> Date {
            let base = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
        }

        let categories = (try? context.fetch(FetchDescriptor<LedgerCategory>())) ?? []
        let accounts = (try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        func category(_ key: String) -> LedgerCategory? { categories.first { $0.seedKey == key } }
        func account(_ kind: AccountKind) -> Account? { accounts.first { $0.kind == kind } }
        let currency = accounts.first?.currencyCode ?? AppSettings.defaultBaseCurrency

        // Tasks
        let report = TaskItem(title: String(localized: "交季度报告"), dueDate: day(0, 18), hasDueTime: true, priority: .high, listName: String(localized: "工作"))
        let call = TaskItem(title: String(localized: "给妈妈打电话"), dueDate: day(0), listName: String(localized: "家庭"))
        let dentist = TaskItem(title: String(localized: "预约牙医"), dueDate: day(1, 10), hasDueTime: true, listName: String(localized: "健康"))
        dentist.recurrence = Recurrence(frequency: .monthly, interval: 6, monthDay: calendar.component(.day, from: day(1)))
        let groceries = TaskItem(title: String(localized: "买菜"), dueDate: day(3), listName: String(localized: "家庭"))
        [report, call, dentist, groceries].forEach(context.insert)
        let item = Subtask(title: String(localized: "整理销售数据"), order: 0)
        context.insert(item)
        item.task = report

        // Ledger entries for the current month, spread over the days so far.
        let dayOfMonth = calendar.component(.day, from: now)
        let spending: [(Int, String, Decimal, String, AccountKind)] = [
            (0, "food", 35, String(localized: "午餐"), .eWallet),
            (0, "transport", 6, String(localized: "地铁"), .eWallet),
            (1, "shopping", 268, String(localized: "运动鞋"), .creditCard),
            (1, "food", 128.5, String(localized: "和朋友吃饭"), .creditCard),
            (2, "fun", 89, String(localized: "电影"), .eWallet),
            (3, "food", 42, "", .eWallet),
            (4, "telecom", 98, String(localized: "话费"), .debitCard),
            (5, "housing", 3500, String(localized: "房租"), .debitCard),
            (6, "health", 120, String(localized: "体检"), .debitCard),
        ]
        for (offset, key, amount, note, kind) in spending where offset < dayOfMonth {
            let entry = LedgerEntry(kind: .expense, amount: amount, currencyCode: currency, date: day(-offset, 12 + offset % 6), note: note)
            context.insert(entry)
            entry.category = category(key)
            entry.account = account(kind)
        }
        let salary = LedgerEntry(kind: .income, amount: 12000, currencyCode: currency, date: calendar.date(byAdding: .day, value: 1 - dayOfMonth, to: today) ?? today, note: String(localized: "十月工资"))
        context.insert(salary)
        salary.category = category("salary")
        salary.account = account(.debitCard)

        // A few earlier months, so the yearly chart has history.
        let monthStart = now.startOfMonth(calendar: calendar)
        for back in 1...9 {
            guard let month = calendar.date(byAdding: .month, value: -back, to: monthStart) else { continue }
            func on(_ day: Int, _ hour: Int = 12) -> Date {
                calendar.date(byAdding: DateComponents(day: day - 1, hour: hour), to: month) ?? month
            }
            let monthly: [(Int, String, Decimal, String, AccountKind)] = [
                (1, "housing", 3500, String(localized: "房租"), .debitCard),
                (3, "food", Decimal(620 + back * 37 % 210), String(localized: "外卖和聚餐"), .eWallet),
                (8, "shopping", Decimal(180 + back * 91 % 520), String(localized: "日用品"), .creditCard),
                (12, "transport", Decimal(140 + back * 13 % 60), String(localized: "地铁和打车"), .eWallet),
                (18, "fun", Decimal(back % 3 == 0 ? 460 : 120), String(localized: "周末出去玩"), .creditCard),
                (22, "telecom", 98, String(localized: "话费"), .debitCard),
            ]
            for (day, key, amount, note, kind) in monthly {
                let entry = LedgerEntry(kind: .expense, amount: amount, currencyCode: currency, date: on(day), note: note)
                context.insert(entry)
                entry.category = category(key)
                entry.account = account(kind)
            }
            let pay = LedgerEntry(kind: .income, amount: back % 4 == 0 ? 15000 : 12000, currencyCode: currency, date: on(1, 9),
                                  note: back % 4 == 0 ? String(localized: "工资和季度奖金") : String(localized: "工资"))
            context.insert(pay)
            pay.category = category("salary")
            pay.account = account(.debitCard)
        }

        // Notes: a long-running log with a reminder on one sentence, and a pinned reference note.
        let renovation = Note(title: String(localized: "装修记录"))
        context.insert(renovation)
        let plan = renovation.append(String(localized: "和设计师确认了方案：客厅铺木地板，厨房和卫生间铺瓷砖。预算控制在 12 万以内。"), date: day(-20, 19), in: context)
        plan.isKeyPoint = true
        plan.highlights = [String(localized: "预算控制在 12 万以内。")]
        renovation.append(String(localized: "水电改造完成，打压测试 0.8MPa 保压半小时没问题。开关插座的位置拍照留底了。"), date: day(-9, 18), in: context)
        let tileSentence = String(localized: "师傅说水泥要养护 7 天，下周三可以铺砖。")
        let tiles = renovation.append(String(localized: "瓷砖到货了，一共 42 箱，有两块边角磕坏，商家答应补发。") + tileSentence, date: day(-1, 20), in: context)
        let thisWednesday = calendar.nextDate(after: today, matching: DateComponents(weekday: 4), matchingPolicy: .nextTime) ?? day(2)
        let tiling = TaskItem(title: String(localized: "铺砖"), dueDate: calendar.date(byAdding: .day, value: 7, to: thisWednesday), listName: String(localized: "装修"))
        context.insert(tiling)
        tiling.sourceEntry = tiles
        tiling.sourceQuote = tileSentence
        // Two photos on that entry, so the photo viewer has something to swipe through.
        for colors in [(UIColor.systemBrown, UIColor.systemGray5), (UIColor.systemGray, UIColor.systemGray6)] {
            if let photo = samplePhoto(tile: colors.0, grout: colors.1) {
                let attachment = Attachment(imageData: photo.full, thumbnailData: photo.thumbnail)
                context.insert(attachment)
                attachment.noteEntry = tiles
            }
        }
        renovation.updatedAt = day(-1, 20)

        let checkup = Note(title: String(localized: "体检复查"))
        context.insert(checkup)
        let checkupSentence = String(localized: "体检报告出来了，甘油三酯偏高 2.1，医生说注意饮食，三个月后复查血脂。")
        let bloodWork = checkup.append(checkupSentence, date: day(-30, 10), in: context)
        let recheck = TaskItem(title: String(localized: "复查血脂"), dueDate: day(60), listName: String(localized: "健康"))
        context.insert(recheck)
        recheck.sourceEntry = bloodWork
        recheck.sourceQuote = checkupSentence
        checkup.updatedAt = day(-30, 10)

        let info = Note(title: String(localized: "家里常用信息"))
        info.isPinned = true
        context.insert(info)
        info.append(String(localized: "Wi-Fi：Home-5G，密码贴在路由器背面。\n物业电话：0571-8888 6666（白天）\n燃气表号：3301 2234 5678"), date: day(-60, 21), in: context)
        info.updatedAt = day(-60, 21)

        context.insert(Budget(amount: 6000))

        // Bills
        let card = Bill(name: String(localized: "信用卡还款"), kind: .creditCard, amount: 2180, currencyCode: currency,
                        nextDueDate: Recurrence.firstMonthly(day: 15, onOrAfter: day(0)), recurrence: .monthly(day: 15))
        let video = Bill(name: String(localized: "视频会员续费"), kind: .subscription, amount: 25, currencyCode: currency,
                         nextDueDate: day(7), recurrence: .monthly(day: calendar.component(.day, from: day(7))))
        let rent = Bill(name: String(localized: "房租"), kind: .rent, amount: 3500, currencyCode: currency,
                        nextDueDate: Recurrence.firstMonthly(day: 1, onOrAfter: day(1)), recurrence: .monthly(day: 1))
        [card, video, rent].forEach(context.insert)
        card.account = account(.debitCard)
        card.creditAccount = account(.creditCard)
        video.account = account(.creditCard)
        video.category = category("fun")
        rent.account = account(.debitCard)
        rent.category = category("housing")

        // Expiry items
        let insurance = ExpiryItem(name: String(localized: "车险"), kind: .insurance, expiryDate: day(40))
        insurance.renewalMonths = 12
        let passportDate = calendar.date(from: DateComponents(year: calendar.component(.year, from: now) + 1, month: 3, day: 1)) ?? day(150)
        let passport = ExpiryItem(name: String(localized: "护照"), kind: .document, expiryDate: passportDate, isDayUncertain: true)
        passport.renewalMonths = 120
        [insurance, passport].forEach(context.insert)

        try? context.save()
    }

    /// A floor of tiles, drawn rather than shipped as a file.
    private static func samplePhoto(tile: UIColor, grout: UIColor) -> (full: Data, thumbnail: Data)? {
        let size = CGSize(width: 1600, height: 1200)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            grout.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for row in 0..<6 {
                for column in 0..<8 {
                    let shade = CGFloat((row + column) % 3) * 0.06
                    tile.withAlphaComponent(1 - shade).setFill()
                    context.fill(CGRect(x: CGFloat(column) * 200 + 6, y: CGFloat(row) * 200 + 6, width: 188, height: 188))
                }
            }
        }
        return image.jpegData(compressionQuality: 0.9).flatMap { ImageTools.prepare($0) }
    }

    static func deleteAll(_ context: ModelContext) {
        try? context.delete(model: Attachment.self)
        try? context.delete(model: NoteEntry.self)
        try? context.delete(model: Note.self)
        try? context.delete(model: Subtask.self)
        try? context.delete(model: TaskItem.self)
        try? context.delete(model: LedgerEntry.self)
        try? context.delete(model: Budget.self)
        try? context.delete(model: Bill.self)
        try? context.delete(model: Outstanding.self)
        try? context.delete(model: ExpiryItem.self)
        try? context.delete(model: Account.self)
        try? context.delete(model: LedgerCategory.self)
        try? context.save()
    }
    #endif
}
