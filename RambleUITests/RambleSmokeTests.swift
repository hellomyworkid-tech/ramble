import XCTest

/// Walks through what has broken before and was only caught by hand: the app opening, a capture,
/// tapping a reminder, opening a photo, swiping in a note, deleting from each list, the ledger by
/// category, 问一问. Sample data, kept in memory, so nothing in the simulator's library changes. Run
/// with scripts/build.sh uitest.
final class RambleSmokeTests: XCTestCase {
    private let timeout: TimeInterval = 10

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ arguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        // The count of saved captures stays at nothing: runs add up, and a rating prompt would cover the page.
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "-inMemoryStore", "-sampleData", "-mockAI", "-review.savedCaptures", "0"] + arguments
        app.launch()
        return app
    }

    @MainActor
    private func expect(_ element: XCUIElement, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), message, file: file, line: line)
    }

    /// The tab bar item, in whichever form the system gives it.
    @MainActor
    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.tabBars.buttons[name].firstMatch
    }

    @MainActor
    func testEveryTabOpens() {
        let app = launch("-startTab", "today")
        for name in ["待办", "笔记", "账本", "提醒", "今天"] {
            let button = tab(app, name)
            expect(button, "The \(name) tab is missing")
            button.tap()
            expect(app.navigationBars[name].firstMatch, "\(name) didn't open")
        }
    }

    /// A library that won't open shows a way out instead of crashing, and 取消 changes nothing.
    @MainActor
    func testABrokenLibraryOffersAWayOut() {
        let app = launch("-testBrokenLibrary")
        let page = app.navigationBars["资料库打不开了"].firstMatch
        expect(page, "The recovery page didn't show")
        XCTAssertFalse(tab(app, "今天").exists, "The app opened over a library that won't open")

        app.buttons["再试一次"].firstMatch.tap()
        expect(page, "再试一次 left the page while the library still won't open")

        let startOver = app.buttons["重新开始"].firstMatch
        startOver.tap()
        let alert = app.alerts.firstMatch
        expect(alert, "重新开始 didn't ask first")
        alert.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: timeout), "The alert didn't close")
        XCTAssertTrue(page.exists, "取消 left the page")

        startOver.tap()
        expect(alert, "重新开始 didn't ask the second time")
        alert.buttons["重新开始"].firstMatch.tap()
        expect(tab(app, "今天"), "The app didn't open after starting over")
        XCTAssertFalse(page.exists, "The recovery page stayed")
    }

    /// Say something, read what AI made of it, save it, and find it in the ledger.
    @MainActor
    func testACaptureEndsUpInTheLedger() {
        let app = launch("-startTab", "today", "-ledger.grouping", "date", "-debugCaptureText", "装修那边今天买瓷砖花了 3200")
        let bar = app.buttons["快速记录"].firstMatch
        expect(bar, "The capture bar is missing")
        bar.tap()

        let tidy = app.buttons["整理"].firstMatch
        expect(tidy, "整理 is missing")
        tidy.tap()

        let save = app.buttons["保存 3 条"].firstMatch
        expect(save, "The result of tidying didn't appear")
        save.tap()

        let ledger = tab(app, "账本")
        expect(ledger, "The capture sheet didn't close")
        ledger.tap()
        expect(app.staticTexts["瓷砖"].firstMatch, "The saved expense isn't in the ledger")
    }

    /// Words from the share sheet wait for the app, which tidies them as it opens.
    @MainActor
    func testSharedWordsAreTidiedWhenTheAppOpens() {
        let app = launch("-startTab", "today", "-testShare", "装修那边今天买瓷砖花了 3200")
        let save = app.buttons["保存 3 条"].firstMatch
        expect(save, "What was shared wasn't tidied")
        save.tap()
        expect(tab(app, "账本"), "The capture sheet didn't close")
        // Handled once: it doesn't come back.
        XCTAssertFalse(app.buttons["保存 3 条"].waitForExistence(timeout: 2), "The same share opened again")
    }

    /// A shared file waits with room to say what it is, and 「AI 读一下」 reads it.
    /// On iOS 27 this button froze the app for good: the page it opens re-created itself endlessly.
    @MainActor
    func testASharedFileIsReadWhenAsked() {
        let app = launch("-startTab", "today", "-testShareFile", "瓷砖质保单，质保期 10 年，售后电话 400-820-1234。")
        let read = app.buttons["AI 读一下"].firstMatch
        expect(read, "The shared file isn't waiting")
        read.tap()
        expect(app.navigationBars["读取结果"].firstMatch, "The file wasn't read")
    }

    /// The × on an attachment is centered on the corner badge: forgiving enough to hit cleanly,
    /// without reaching into the middle of a small thumbnail where a tap should open the picture.
    @MainActor
    func testAnAttachmentsRemoveButtonIsEasyToHit() {
        let app = launch("-startTab", "today", "-testShareFile", "瓷砖质保单")
        let remove = app.buttons["移除"].firstMatch
        expect(remove, "The attachment has no ×")
        XCTAssertGreaterThanOrEqual(remove.frame.width, 27.5)
        XCTAssertGreaterThanOrEqual(remove.frame.height, 27.5)
        XCTAssertLessThanOrEqual(remove.frame.width, 32)

        // Slightly off the glyph towards the tile: where a thumb lands on the corner.
        remove.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.65)).tap()
        expect(app.buttons["整理"].firstMatch, "That opened the file instead of removing it")
    }

    /// On a 56×56 pending photo in the note composer (with the keyboard up), tapping the thumbnail
    /// opens the photo viewer instead of triggering ×, and tapping × removes it.
    @MainActor
    func testPendingPhotoInNoteOpensOnTapAndRemovesOnCorner() {
        let app = launch("-startTab", "notes", "-openNote", "体检复查", "-debugNotePhoto")
        let photo = app.buttons["照片"].firstMatch
        expect(photo, "The pending photo is missing")

        let box = app.textViews["写一条记录，或者点麦克风说"].exists ? app.textViews["写一条记录，或者点麦克风说"].firstMatch
                                                             : app.textFields["写一条记录，或者点麦克风说"].firstMatch
        box.tap()
        let hadSoftwareKeyboard = app.keyboards.firstMatch.waitForExistence(timeout: 2)

        // Slightly upper-right of center: the old 44×44 × reached past (28, 28) and deleted the photo here.
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.45)).tap()

        let close = app.buttons["关闭"].firstMatch
        expect(close, "Tapping the pending photo didn't open the viewer (or deleted it)")
        if hadSoftwareKeyboard {
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: timeout), "The keyboard stayed over the viewer")
        }
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: timeout), "The photo viewer didn't close")
        XCTAssertTrue(photo.exists, "The pending photo was removed instead of previewed")

        let remove = app.buttons["移除"].firstMatch
        expect(remove, "The pending photo has no ×")
        remove.tap()
        XCTAssertTrue(photo.waitForNonExistence(timeout: timeout), "Tapping × didn't remove the pending photo")
    }

    // MARK: Swiping an entry in a note

    @MainActor
    private func entry(_ app: XCUIApplication, saying text: String) -> XCUIElement {
        app.cells.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// An entry well inside the page, clear of the bars at the top and bottom.
    @MainActor
    private func entryInView(_ app: XCUIApplication, saying text: String) -> XCUIElement {
        let rows = app.cells.containing(NSPredicate(format: "label CONTAINS %@", text)).allElementsBoundByIndex
        return rows.first { $0.frame.minY > 150 && $0.frame.maxY < 650 } ?? app.cells.firstMatch
    }

    /// Scrolls the page in small steps until `element` is in the open part of it, clear of the bars,
    /// the composer and the keyboard. One not loaded yet is taken to be further up, with a note's
    /// older entries. Flicking would overshoot it.
    @MainActor
    private func bringIntoView(_ element: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch
        for _ in 1...20 {
            // `isHittable` doesn't know about the composer: it says yes to a row behind it.
            let keyboard = app.keyboards.firstMatch
            let bottom = (keyboard.exists ? keyboard.frame.minY : window.frame.maxY) - 80
            let revealsBelow: Bool
            if element.exists, element.frame.midY > bottom {
                revealsBelow = true
            } else if !element.exists || element.frame.midY < 140 {
                revealsBelow = false
            } else {
                return
            }
            let (from, to) = revealsBelow ? (0.4, 0.25) : (0.25, 0.4)
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)))
            sleep(1)
        }
    }

    /// A short drag that shows the actions on one side without running them.
    @MainActor
    private func showActions(of cell: XCUIElement, fromLeading: Bool) {
        let (from, to) = fromLeading ? (0.1, 0.55) : (0.9, 0.45)
        cell.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: cell.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.5)))
    }

    /// 重点 from the swipe, over and over.
    @MainActor
    func testKeyPointFromTheSwipeAlwaysTakes() {
        let app = launch("-startTab", "notes", "-openNote", "装修记录")
        let cell = entry(app, saying: "水电改造")
        expect(cell, "The entry is missing")

        for round in 1...8 {
            showActions(of: cell, fromLeading: true)
            let mark = app.buttons["重点"].firstMatch
            expect(mark, "重点 didn't show (round \(round))")
            mark.tap()
            expect(cell.staticTexts["重点"].firstMatch, "重点 didn't take (round \(round))")

            showActions(of: cell, fromLeading: true)
            let unmark = app.buttons["取消重点"].firstMatch
            expect(unmark, "取消重点 didn't show (round \(round))")
            unmark.tap()
            XCTAssertTrue(cell.staticTexts["重点"].firstMatch.waitForNonExistence(timeout: timeout), "取消重点 didn't take (round \(round))")
        }
    }

    /// A tap that drifts up or down still counts. Past about 10 points the list used to start
    /// scrolling, which shut the actions with nothing done.
    @MainActor
    func testASwipeActionTakesATapThatDrifts() {
        let app = launch("-startTab", "notes", "-openNote", "装修记录")
        let cell = entry(app, saying: "水电改造")
        expect(cell, "The entry is missing")

        func tap(_ title: String, drifting drift: Double) {
            showActions(of: cell, fromLeading: true)
            let action = app.buttons[title].firstMatch
            expect(action, "\(title) didn't show")
            sleep(1)
            let start = action.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: drift)),
                        withVelocity: .slow, thenHoldForDuration: 0)
        }
        tap("重点", drifting: 16)
        expect(cell.staticTexts["重点"].firstMatch, "A tap drifting down didn't take")
        tap("取消重点", drifting: -16)
        XCTAssertTrue(cell.staticTexts["重点"].firstMatch.waitForNonExistence(timeout: timeout), "A tap drifting up didn't take")
    }

    /// The same as the first with the keyboard up.
    @MainActor
    func testKeyPointFromTheSwipeTakesWithTheKeyboardUp() {
        let app = launch("-startTab", "notes", "-openNote", "装修记录")
        let cell = entry(app, saying: "水电改造")
        expect(cell, "The entry is missing")

        for round in 1...4 {
            let box = app.textViews["写一条记录，或者点麦克风说"].exists ? app.textViews["写一条记录，或者点麦克风说"].firstMatch
                                                                 : app.textFields["写一条记录，或者点麦克风说"].firstMatch
            // It stays up after a swipe action. Tapping the box again would bring up the text menu.
            if !app.keyboards.firstMatch.exists { box.tap() }
            expect(app.keyboards.firstMatch, "The keyboard didn't come up (round \(round))")
            bringIntoView(cell, in: app)
            showActions(of: cell, fromLeading: true)
            let mark = app.buttons["重点"].firstMatch
            expect(mark, "重点 didn't show (round \(round))")
            mark.tap()
            expect(cell.staticTexts["重点"].firstMatch, "重点 didn't take with the keyboard up (round \(round))")

            showActions(of: cell, fromLeading: true)
            let unmark = app.buttons["取消重点"].firstMatch
            expect(unmark, "取消重点 didn't show (round \(round))")
            unmark.tap()
            XCTAssertTrue(cell.staticTexts["重点"].firstMatch.waitForNonExistence(timeout: timeout), "取消重点 didn't take (round \(round))")
        }
    }

    /// Anywhere on an entry puts the composer's keyboard away, the blank part beside its words too.
    @MainActor
    func testTappingAnEntryPutsTheKeyboardAway() {
        let app = launch("-startTab", "notes", "-openNote", "装修记录")
        let cell = entry(app, saying: "水电改造")
        expect(cell, "The entry is missing")
        let box = app.textViews["写一条记录，或者点麦克风说"].exists ? app.textViews["写一条记录，或者点麦克风说"].firstMatch
                                                             : app.textFields["写一条记录，或者点麦克风说"].firstMatch
        box.tap()
        expect(app.keyboards.firstMatch, "The keyboard didn't come up")

        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.2)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: timeout), "The keyboard stayed up")
    }

    /// Reading further up, a photo is opened and closed. The page stays where it was.
    @MainActor
    func testAPhotoLeavesThePageWhereItWas() {
        let app = launch("-startTab", "notes", "-openNote", "装修记录", "-testLongNote")
        expect(entry(app, saying: "第 30 条记录"), "The page didn't open at the end")

        let photo = app.buttons["照片"].firstMatch
        bringIntoView(photo, in: app)
        XCTAssertTrue(photo.exists && photo.isHittable, "The note's photo is missing")
        sleep(1)
        let before = photo.frame.minY
        photo.tap()
        let close = app.buttons["关闭"].firstMatch
        expect(close, "The photo viewer didn't open")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: timeout), "The photo viewer didn't close")
        sleep(1)
        XCTAssertTrue(photo.exists && photo.isHittable, "The page moved away from the photo")
        XCTAssertEqual(photo.frame.minY, before, accuracy: 2, "The page moved")
    }

    /// Reading further up, an entry is deleted. When 撤销 ran out the page jumped to the end.
    @MainActor
    func testDeletingDoesNotMoveThePage() {
        let app = launch("-startTab", "notes", "-openNote", "装修记录", "-testLongNote")
        let first = entry(app, saying: "第 30 条记录")
        expect(first, "The page didn't open at the end")

        // Up to somewhere in the middle.
        let window = app.windows.firstMatch
        for _ in 1...3 { window.swipeDown(velocity: .fast) }
        sleep(2)
        showActions(of: entryInView(app, saying: "条记录"), fromLeading: false)
        expect(app.buttons["删除"].firstMatch, "删除 didn't show")
        app.buttons["删除"].firstMatch.tap()
        expect(app.alerts.firstMatch, "Deleting didn't ask first")
        app.alerts.buttons["删除"].firstMatch.tap()
        expect(app.buttons["撤销"].firstMatch, "撤销 didn't show")

        let shown = entryInView(app, saying: "条记录")
        let label = shown.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "条记录")).firstMatch.label
        let before = shown.frame.minY
        // 撤销 runs out after 8 seconds, and the entry goes for good.
        XCTAssertTrue(app.buttons["撤销"].firstMatch.waitForNonExistence(timeout: 12), "撤销 didn't go away")
        sleep(2)
        let after = entry(app, saying: label)
        XCTAssertTrue(after.exists && after.isHittable, "The page moved away from \(label)")
        XCTAssertFalse(entry(app, saying: "第 30 条记录").isHittable, "The page jumped to the end")
        XCTAssertLessThan(abs(after.frame.minY - before), 80, "The page moved")
    }

    /// With a row's actions showing, 撤销 running out for another entry leaves them showing.
    @MainActor
    func testUndoRunningOutLeavesASwipeOpen() {
        let app = launch("-startTab", "notes", "-openNote", "装修记录", "-testLongNote")
        let last = entry(app, saying: "第 30 条记录")
        expect(last, "The page didn't open at the end")

        let window = app.windows.firstMatch
        for _ in 1...2 { window.swipeDown(velocity: .fast) }
        sleep(2)
        showActions(of: entryInView(app, saying: "条记录"), fromLeading: false)
        expect(app.buttons["删除"].firstMatch, "删除 didn't show")
        app.buttons["删除"].firstMatch.tap()
        expect(app.alerts.firstMatch, "Deleting didn't ask first")
        app.alerts.buttons["删除"].firstMatch.tap()
        expect(app.buttons["撤销"].firstMatch, "撤销 didn't show")

        showActions(of: entryInView(app, saying: "条记录"), fromLeading: true)
        expect(app.buttons["设提醒"].firstMatch, "The actions didn't show")
        XCTAssertTrue(app.buttons["撤销"].firstMatch.waitForNonExistence(timeout: 12), "撤销 didn't go away")
        sleep(1)
        XCTAssertTrue(app.buttons["设提醒"].firstMatch.exists, "The actions slid shut when 撤销 ran out")
    }

    /// At the very end of a note, 撤销 coming and going moves nothing.
    @MainActor
    func testTheUndoBarDoesNotMoveThePage() {
        let app = launch("-startTab", "notes", "-openNote", "装修记录", "-testLongNote")
        let last = entry(app, saying: "第 30 条记录")
        expect(last, "The page didn't open at the end")
        app.windows.firstMatch.swipeUp(velocity: .fast)
        sleep(1)

        let doomed = entry(app, saying: "第 29 条记录")
        expect(doomed, "No entry in view")
        showActions(of: doomed, fromLeading: false)
        expect(app.buttons["删除"].firstMatch, "删除 didn't show")
        app.buttons["删除"].firstMatch.tap()
        expect(app.alerts.firstMatch, "Deleting didn't ask first")
        app.alerts.buttons["删除"].firstMatch.tap()
        expect(app.buttons["撤销"].firstMatch, "撤销 didn't show")
        sleep(1)
        let before = last.frame.minY
        XCTAssertTrue(app.buttons["撤销"].firstMatch.waitForNonExistence(timeout: 12), "撤销 didn't go away")
        sleep(1)
        XCTAssertEqual(last.frame.minY, before, accuracy: 2, "The page moved when 撤销 went")
    }

    // MARK: Deleting from a list

    /// A long swipe only shows 删除, and 删除 takes a second tap, in an alert with 取消. Once
    /// confirmed, where the list has it, 撤销 brings the row back.
    @MainActor
    private func checkDeleting(_ app: XCUIApplication, saying text: String, confirms: Bool = true, undoes: Bool = true,
                               file: StaticString = #filePath, line: UInt = #line) {
        let cell = entry(app, saying: text)
        expect(cell, "「\(text)」 is missing", file: file, line: line)
        // Counted: a run that stopped halfway can leave conversations with the same words.
        let rows = app.cells.containing(NSPredicate(format: "label CONTAINS %@", text))
        let count = rows.count
        sleep(1)
        let everyRow = app.cells.count

        // All the way across, fast: the row's first action would run if that were allowed.
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: cell.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)))
        sleep(1)
        XCTAssertFalse(app.alerts.firstMatch.exists, "A long swipe asked to delete", file: file, line: line)
        XCTAssertFalse(app.buttons["撤销"].firstMatch.exists, "A long swipe deleted it", file: file, line: line)
        XCTAssertTrue(cell.exists, "A long swipe took it away", file: file, line: line)

        let delete = app.buttons["删除"].firstMatch
        if !delete.exists { showActions(of: cell, fromLeading: false) }
        expect(delete, "删除 didn't show", file: file, line: line)
        delete.tap()
        let alert = app.alerts.firstMatch
        expect(alert, "Deleting didn't ask first", file: file, line: line)
        alert.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: timeout), "The alert didn't close", file: file, line: line)
        XCTAssertFalse(app.buttons["撤销"].firstMatch.exists, "取消 deleted it", file: file, line: line)
        XCTAssertTrue(cell.waitForExistence(timeout: timeout), "取消 lost it", file: file, line: line)
        // Whichever row: the list used to drop the section's last one, with the data untouched.
        XCTAssertTrue(wait(for: app.cells, toNumber: everyRow), "取消 lost a row", file: file, line: line)

        guard confirms else { return }

        showActions(of: cell, fromLeading: false)
        expect(delete, "删除 didn't show again", file: file, line: line)
        delete.tap()
        expect(alert, "Deleting didn't ask the second time", file: file, line: line)
        // 「删除」, or for a whole note 「删除「…」」.
        alert.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "删除")).firstMatch.tap()
        XCTAssertTrue(wait(for: rows, toNumber: count - 1), "It stayed", file: file, line: line)
        guard undoes else { return }
        expect(app.buttons["撤销"].firstMatch, "撤销 didn't show", file: file, line: line)
        app.buttons["撤销"].firstMatch.tap()
        XCTAssertTrue(wait(for: rows, toNumber: count), "撤销 didn't bring it back", file: file, line: line)
    }

    @MainActor
    private func wait(for rows: XCUIElementQuery, toNumber count: Int) -> Bool {
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", count), object: rows)
        return XCTWaiter.wait(for: [counted], timeout: timeout) == .completed
    }

    /// 删除 in the long-press menu asks as well.
    @MainActor
    private func checkDeletingFromTheMenu(_ app: XCUIApplication, saying text: String,
                                          file: StaticString = #filePath, line: UInt = #line) {
        let cell = entry(app, saying: text)
        expect(cell, "「\(text)」 is missing", file: file, line: line)
        cell.press(forDuration: 1)
        let delete = app.buttons["删除"].firstMatch
        expect(delete, "The menu has no 删除", file: file, line: line)
        delete.tap()
        let alert = app.alerts.firstMatch
        expect(alert, "The menu's 删除 didn't ask first", file: file, line: line)
        alert.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: timeout), "The alert didn't close", file: file, line: line)
        XCTAssertFalse(app.buttons["撤销"].firstMatch.exists, "取消 deleted it", file: file, line: line)
    }

    @MainActor
    func testDeletingAnEntryAsksFirst() {
        let app = launch("-startTab", "notes", "-openNote", "装修记录")
        checkDeleting(app, saying: "水电改造")
    }

    @MainActor
    func testDeletingANoteAsksFirst() {
        let app = launch("-startTab", "notes")
        checkDeleting(app, saying: "装修记录")
    }

    @MainActor
    func testDeletingFromTheLedgerAsksFirst() {
        let app = launch("-startTab", "ledger", "-ledger.grouping", "date")
        expect(entry(app, saying: "午餐"), "The entry is missing")
        // Up off the capture bar.
        let list = app.collectionViews.firstMatch
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        checkDeleting(app, saying: "午餐")
    }

    @MainActor
    func testDeletingAToDoAsksFirst() {
        let app = launch("-startTab", "tasks")
        checkDeleting(app, saying: "交季度报告")
    }

    @MainActor
    func testDeletingABillAsksFirst() {
        let app = launch("-startTab", "reminders")
        checkDeleting(app, saying: "信用卡还款")
        checkDeletingFromTheMenu(app, saying: "信用卡还款")
    }

    @MainActor
    func testDeletingAnExpiryAsksFirst() {
        let app = launch("-startTab", "reminders")
        let expiries = app.buttons["到期"].firstMatch
        expect(expiries, "到期 is missing")
        expiries.tap()
        checkDeleting(app, saying: "车险")
    }

    /// A long swipe only shows 已续期: it moves the date on with no 撤销, so it takes a tap of its own.
    @MainActor
    func testALongSwipeDoesNotRenewAnExpiry() {
        let app = launch("-startTab", "reminders")
        let expiries = app.buttons["到期"].firstMatch
        expect(expiries, "到期 is missing")
        expiries.tap()
        let cell = entry(app, saying: "车险")
        expect(cell, "车险 is missing")
        let date = cell.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", " · ")).firstMatch.label

        // All the way across, fast: 已续期 would run if that were allowed.
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: cell.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)))
        sleep(1)
        XCTAssertTrue(cell.staticTexts[date].exists, "A long swipe renewed it")

        let renew = app.buttons["已续期"].firstMatch
        if !renew.exists { showActions(of: cell, fromLeading: true) }
        expect(renew, "已续期 didn't show")
        renew.tap()
        XCTAssertTrue(cell.staticTexts[date].waitForNonExistence(timeout: timeout), "已续期 didn't take")
    }

    @MainActor
    func testDeletingAnOutstandingAsksFirst() {
        let app = launch("-startTab", "ledger")
        let outstanding = app.staticTexts["应收应付"].firstMatch
        expect(outstanding, "应收应付 is missing")
        outstanding.tap()
        checkDeleting(app, saying: "借款")
        checkDeletingFromTheMenu(app, saying: "借款")
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication, _ page: String) {
        let settings = app.buttons["设置"].firstMatch
        expect(settings, "设置 is missing")
        settings.tap()
        let row = app.staticTexts[page].firstMatch
        expect(row, "\(page) is missing")
        row.tap()
    }

    /// These go at once, with no 撤销: every entry in a category loses it.
    @MainActor
    func testDeletingACategoryAsksFirst() {
        let app = launch("-startTab", "today")
        openSettings(app, "分类")
        checkDeleting(app, saying: "餐饮", undoes: false)
    }

    @MainActor
    func testDeletingABudgetAsksFirst() {
        let app = launch("-startTab", "today")
        openSettings(app, "预算")
        // Its words, not the middle of the row: only they open the menu.
        let add = app.staticTexts["添加分类预算"].firstMatch
        expect(add, "添加分类预算 is missing")
        add.tap()
        let category = app.buttons["餐饮"].firstMatch
        expect(category, "The menu has no 餐饮")
        category.tap()
        let amount = app.alerts.textFields.firstMatch
        expect(amount, "The amount wasn't asked for")
        amount.typeText("1000")
        app.alerts.buttons["保存"].firstMatch.tap()
        // Not on to confirming: after 取消, this page's actions show and work but tests can't find them.
        checkDeleting(app, saying: "餐饮", confirms: false)
    }

    @MainActor
    func testDeletingAProjectAsksFirst() {
        let app = launch("-startTab", "ledger", "-ledger.grouping", "date")
        let projects = app.staticTexts["项目"].firstMatch
        expect(projects, "项目 is missing")
        projects.tap()
        checkDeleting(app, saying: "装修")
    }

    @MainActor
    private func openRecurringEntries(_ app: XCUIApplication) {
        let manage = app.buttons["管理"].firstMatch
        expect(manage, "管理 is missing")
        manage.tap()
        let recurring = app.buttons["定期记账"].firstMatch
        expect(recurring, "管理 has no 定期记账")
        recurring.tap()
    }

    @MainActor
    func testDeletingARecurringEntryAsksFirst() {
        let app = launch("-startTab", "ledger", "-ledger.grouping", "date")
        openRecurringEntries(app)
        checkDeleting(app, saying: "工资")
    }

    // MARK: Refunds, projects and recurring entries

    /// An expense swiped right: the money comes off it.
    @MainActor
    func testARefundComesOffTheExpense() {
        let app = launch("-startTab", "ledger", "-ledger.grouping", "date")
        let cell = entry(app, saying: "午餐")
        expect(cell, "The entry is missing")
        // Up off the capture bar.
        let list = app.collectionViews.firstMatch
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        sleep(1)

        showActions(of: cell, fromLeading: true)
        let refund = app.buttons["退款"].firstMatch
        expect(refund, "退款 didn't show")
        refund.tap()
        let confirm = app.buttons["确认退款"].firstMatch
        expect(confirm, "The refund page didn't open")
        confirm.tap()
        expect(cell.staticTexts["已全额退款"].firstMatch, "The entry doesn't say it was refunded")
    }

    @MainActor
    func testAProjectAddsUpAcrossCategories() {
        let app = launch("-startTab", "ledger", "-ledger.grouping", "date")
        let projects = app.staticTexts["项目"].firstMatch
        expect(projects, "项目 is missing")
        projects.tap()
        let project = app.staticTexts["装修"].firstMatch
        expect(project, "The project isn't listed")
        project.tap()
        expect(app.staticTexts["一共花了"].firstMatch, "The project's page didn't open")
        expect(app.staticTexts["花在哪"].firstMatch, "The project doesn't say where it went")
        expect(app.staticTexts["灯具"].firstMatch, "The project's entries are missing")
    }

    @MainActor
    func testANoteShowsWhatItsProjectCost() {
        let app = launch("-startTab", "notes", "-openNote", "装修记录")
        expect(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "一共花了")).firstMatch,
               "The note doesn't show what its project cost")
    }

    /// One that asks first waits on 今天 for a yes, then goes into the ledger.
    @MainActor
    func testARecurringEntryThatAsksFirstWaitsOnToday() {
        let app = launch("-startTab", "today", "-ledger.grouping", "date", "-testDueRecurring")
        let row = app.staticTexts["物业费"].firstMatch
        expect(row, "It isn't waiting on 今天")
        row.tap()
        let record = app.buttons["记一笔"].firstMatch
        expect(record, "The page to confirm it didn't open")
        record.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: timeout), "It's still waiting after being recorded")

        tab(app, "账本").tap()
        expect(app.cells.containing(NSPredicate(format: "label CONTAINS %@", "物业费")).firstMatch, "It didn't reach the ledger")
    }

    /// Said out loud: it finds the expense it gives back, and adds nothing to the ledger.
    @MainActor
    func testASpokenRefundFindsTheExpense() {
        let app = launch("-startTab", "today", "-debugCaptureText", "运动鞋退款 268")
        let bar = app.buttons["快速记录"].firstMatch
        expect(bar, "The capture bar is missing")
        bar.tap()
        let tidy = app.buttons["整理"].firstMatch
        expect(tidy, "整理 is missing")
        tidy.tap()
        expect(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "退款")).firstMatch, "It wasn't read as a refund")
        expect(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "运动鞋 ·")).firstMatch, "It didn't find the expense")
    }

    /// 自定义 in 记一笔: name a category there and then, and it's picked.
    @MainActor
    func testACategoryNamedWhileRecording() {
        let app = launch("-startTab", "ledger", "-ledger.grouping", "date")
        let add = app.buttons["记一笔"].firstMatch
        expect(add, "记一笔 is missing")
        add.tap()
        expect(app.keyboards.firstMatch, "The amount isn't being asked for")
        app.typeText("58")

        let custom = app.buttons["自定义"].firstMatch
        expect(custom, "自定义 is missing")
        custom.tap()
        let field = app.alerts.textFields.firstMatch
        expect(field, "The name isn't being asked for")
        field.typeText("宠物")
        app.alerts.buttons["添加"].firstMatch.tap()

        let pets = app.buttons["宠物"].firstMatch
        expect(pets, "The new category isn't there")
        XCTAssertTrue(pets.isSelected, "The new category isn't picked")
        app.buttons["保存"].firstMatch.tap()
        expect(app.cells.containing(NSPredicate(format: "label CONTAINS %@", "宠物")).firstMatch, "The entry isn't in the ledger under it")
    }

    /// 自定义… at the end of a category menu (定期记账, 账单, 应收应付, 整理结果).
    @MainActor
    func testACategoryNamedFromAMenu() {
        let app = launch("-startTab", "ledger", "-ledger.grouping", "date")
        openRecurringEntries(app)
        let salary = app.staticTexts["工资"].firstMatch
        expect(salary, "The salary rule is missing")
        salary.tap()

        let menu = app.buttons["工资"].firstMatch
        expect(menu, "The category menu is missing")
        menu.tap()
        let custom = app.buttons["自定义…"].firstMatch
        expect(custom, "The menu has no 自定义…")
        custom.tap()
        let field = app.alerts.textFields.firstMatch
        expect(field, "The name isn't being asked for")
        field.typeText("兼职")
        app.alerts.buttons["添加"].firstMatch.tap()
        expect(app.buttons["兼职"].firstMatch, "The new category isn't picked")
    }

    /// A real notification, tapped on the home screen: opening one like this used to crash.
    @MainActor
    func testTappingAReminderShowsTheToDo() {
        let app = launch("-startTab", "today", "-testReminder", "交季度报告")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        // Asked once per install, and scheduling waits for the answer.
        let allow = springboard.alerts.buttons.element(boundBy: 1)
        if allow.waitForExistence(timeout: 5) { allow.tap() }

        XCUIDevice.shared.press(.home)
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "交季度报告")).firstMatch
        expect(banner, "The reminder didn't arrive")
        banner.tap()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: timeout), "The app didn't come back")
        expect(app.navigationBars["待办"].firstMatch, "The reminder didn't lead to 待办")
        expect(app.staticTexts["交季度报告"].firstMatch, "The to-do isn't showing")
    }

    @MainActor
    func testAPhotoOpensAndCloses() {
        let app = launch("-startTab", "notes", "-openNote", "装修记录")
        let photo = app.buttons["照片"].firstMatch
        expect(photo, "The note's photo is missing")
        bringIntoView(photo, in: app)
        photo.tap()

        let close = app.buttons["关闭"].firstMatch
        expect(close, "The photo viewer didn't open")
        close.tap()
        expect(app.navigationBars["装修记录"].firstMatch, "The note isn't there behind the photo")
    }

    @MainActor
    func testTheLedgerByCategory() {
        let app = launch("-startTab", "ledger")
        let byCategory = app.buttons["按分类"].firstMatch
        expect(byCategory, "按分类 is missing")
        byCategory.tap()

        let housing = app.staticTexts["居住"].firstMatch
        expect(housing, "The categories didn't appear")
        housing.tap()
        expect(app.staticTexts["房租"].firstMatch, "A category doesn't show its entries")
    }

    /// A question, a follow-up, a new conversation, and the list of earlier ones with its 取消.
    @MainActor
    func testAskingAndConversations() {
        let app = launch("-startTab", "today", "-openAsk")

        let suggestion = app.buttons["这个月吃饭花了多少"].firstMatch
        if !suggestion.waitForExistence(timeout: timeout) {
            // A conversation left by the last run: start from a new one.
            let new = app.buttons["新对话"].firstMatch
            expect(new, "新对话 is missing")
            new.tap()
        }
        expect(suggestion, "The suggestions are missing")
        suggestion.tap()
        expect(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "本月「餐饮」")).firstMatch,
               "The question wasn't answered")

        let box = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        box.tap()
        box.typeText("上个月\n")
        expect(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "上个月")
            .and(NSPredicate(format: "label CONTAINS %@", "餐饮"))).firstMatch,
               "The follow-up didn't keep what was asked about")

        app.buttons["新对话"].firstMatch.tap()
        expect(suggestion, "新对话 didn't start over")

        app.buttons["历史对话"].firstMatch.tap()
        let row = app.staticTexts["这个月吃饭花了多少"].firstMatch
        expect(row, "The earlier conversation isn't listed")
        checkDeleting(app, saying: "这个月吃饭花了多少")

        let clear = app.buttons["清空"].firstMatch
        clear.tap()
        let cancel = app.alerts.buttons["取消"].firstMatch
        expect(cancel, "清空 has no 取消")
        cancel.tap()
        XCTAssertTrue(row.exists, "取消 cleared them anyway")

        clear.tap()
        let confirm = app.alerts.buttons["清空"].firstMatch
        expect(confirm, "清空 has no confirm button")
        confirm.tap()
        expect(app.staticTexts["还没有历史对话"].firstMatch, "清空 left something behind")
    }
}

private extension NSPredicate {
    func and(_ other: NSPredicate) -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: [self, other])
    }
}
