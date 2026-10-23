import Foundation
import UIKit
import Testing
@testable import Ramble

/// The English strings, read straight from the app's en.lproj so the tests don't depend on
/// the simulator's language.
struct LocalizationTests {
    private let english: Bundle = {
        let path = Bundle.main.path(forResource: "en", ofType: "lproj")!
        return Bundle(path: path)!
    }()

    private func en(_ key: String, _ args: CVarArg...) -> String {
        String(format: english.localizedString(forKey: key, value: nil, table: nil), locale: Locale(identifier: "en_US"),
               arguments: args)
    }

    @Test func pluralsFollowTheCount() {
        #expect(en("%lld 个提醒", 1) == "1 reminder")
        #expect(en("%lld 个提醒", 3) == "3 reminders")
        #expect(en("每 %lld 天", 1) == "Every day")
        #expect(en("每 %lld 天", 3) == "Every 3 days")
        #expect(en("逾期 %lld 天", 2) == "2 days overdue")
    }

    @Test func pluralNextToOtherArguments() {
        #expect(en("%@有 %lld 件待办。", "This week", 1) == "This week · 1 to-do.")
        #expect(en("%@%@共 %lld 笔，%@。", "This month", "Expense", 4, "¥120") == "This month · Expense: 4 entries, ¥120.")
        #expect(en("预算已用 %@，还剩 %@，本月还有 %lld 天", "60%", "¥400", 1) == "60% of budget used, ¥400 left, 1 day left this month")
    }

    @Test func reorderedArguments() {
        #expect(en("%@「%@」支出 %@", "This month", "Food", "¥300") == "This month you spent ¥300 on “Food”")
        #expect(en("比%@多 %@（+%@）", "last week", "¥20", "5%") == "up ¥20 (+5%) vs. last week")
    }

    @Test func screenAndKindKeysHaveTheirOwnEnglish() {
        #expect(english.localizedString(forKey: "screen.categories", value: nil, table: nil) == "Categories")
        #expect(english.localizedString(forKey: "kind.task", value: nil, table: nil) == "To-Do")
        // The plain word stays the tab title.
        #expect(english.localizedString(forKey: "待办", value: nil, table: nil) == "To-Dos")
    }

    @Test func dictationJoinsWithTheRightComma() {
        #expect(Punctuation.joining("明天交房租", "三千二") == "明天交房租，三千二")
        #expect(Punctuation.joining("Pay rent", "3200 tomorrow") == "Pay rent, 3200 tomorrow")
        #expect(Punctuation.joining("交房租。", "三千二") == "交房租。三千二")
        #expect(Punctuation.joining("", "hello") == "hello")
    }

    @Test func languageOfAText() {
        #expect(Punctuation.isMostlyChinese("这个月吃饭花了多少"))
        #expect(Punctuation.isMostlyChinese("帮我把 APP 的 bug 记一下"))
        #expect(!Punctuation.isMostlyChinese("How much did I spend on food"))
    }

    @Test func newLibraryTakesTheRegionsCurrency() {
        let defaults = UserDefaults(suiteName: "LocalizationTests.\(UUID().uuidString)")!
        AppSettings.storeBaseCurrencyIfNeeded(isNewLibrary: true, defaults: defaults, locale: Locale(identifier: "en_US"))
        #expect(defaults.string(forKey: AppSettings.baseCurrencyKey) == "USD")
    }

    /// Someone updating from an older version has entries in yuan; their currency doesn't move.
    @Test func existingLibraryKeepsYuan() {
        let defaults = UserDefaults(suiteName: "LocalizationTests.\(UUID().uuidString)")!
        AppSettings.storeBaseCurrencyIfNeeded(isNewLibrary: false, defaults: defaults, locale: Locale(identifier: "en_US"))
        #expect(defaults.string(forKey: AppSettings.baseCurrencyKey) == "CNY")
    }

    @Test func storedCurrencyIsNeverReplaced() {
        let defaults = UserDefaults(suiteName: "LocalizationTests.\(UUID().uuidString)")!
        defaults.set("HKD", forKey: AppSettings.baseCurrencyKey)
        AppSettings.storeBaseCurrencyIfNeeded(isNewLibrary: true, defaults: defaults, locale: Locale(identifier: "en_US"))
        #expect(defaults.string(forKey: AppSettings.baseCurrencyKey) == "HKD")
    }

    @Test func englishTimeWords() throws {
        let now = Date.now
        let calendar = Calendar.current
        let tomorrow = try #require(SpokenDate.resolve("call the bank tomorrow", now: now))
        #expect(tomorrow.date == calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)))
        #expect(!tomorrow.hasTime)
        let withTime = try #require(SpokenDate.resolve("dentist tomorrow at 3pm", now: now))
        #expect(withTime.hasTime)
        #expect(calendar.component(.hour, from: withTime.date) == 15)
    }

    @Test func privacyPolicyShipsInBothLanguages() {
        for language in ["zh-Hans", "en"] {
            let url = Bundle.main.url(forResource: "privacy-\(language)", withExtension: "md")
            let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            let blocks = LegalDocument.parse(text)
            guard case .title = blocks.first else { Issue.record("no title in \(language)"); continue }
            #expect(blocks.filter { if case .heading = $0 { true } else { false } }.count >= 8)
            #expect(text.contains("{{CONTACT_EMAIL}}") || text.contains("@"))
        }
    }
}

/// Portrait on phone-sized displays; free to turn where there's room (iPhone Duo's inner display).
struct OrientationPolicyTests {
    @Test func phonesStayPortrait() {
        #expect(OrientationPolicy.mask(for: CGSize(width: 440, height: 956)) == .portrait)   // the biggest one-display iPhone
        #expect(OrientationPolicy.mask(for: CGSize(width: 956, height: 440)) == .portrait)   // even if launched sideways
        #expect(OrientationPolicy.mask(for: CGSize(width: 466, height: 678)) == .portrait)   // iPhone Duo, closed
        #expect(OrientationPolicy.mask(for: nil) == .portrait)
    }

    @Test func roomyDisplaysTurn() {
        #expect(OrientationPolicy.mask(for: CGSize(width: 890, height: 626)) == .allButUpsideDown)  // iPhone Duo, open
        #expect(OrientationPolicy.mask(for: CGSize(width: 626, height: 890)) == .allButUpsideDown)
    }
}
