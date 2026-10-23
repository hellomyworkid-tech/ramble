import Foundation
import FoundationModels
import Testing
@testable import Ramble

struct OpenModelCatalogTests {
    @Test func modelsAreDistinctAndFolderSafe() {
        #expect(Set(OpenModel.all.map(\.id)).count == OpenModel.all.count)
        #expect(OpenModel.all.allSatisfy { !$0.folderName.contains("/") })
        #expect(OpenModel.find(OpenModel.qwen3_1_7b.id) == .qwen3_1_7b)
        #expect(OpenModel.qwen3_4b.minimumMemoryGB > OpenModel.qwen3_1_7b.minimumMemoryGB)
    }

    @MainActor @Test func anOpenModelThatIsntDownloadedIsntAvailable() {
        let defaults = UserDefaults.standard
        let keys = [LocalAI.engineKey, LocalAI.openModelKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }

        defaults.set(LocalEngine.apple.rawValue, forKey: LocalAI.engineKey)
        #expect(LocalAI.characterBudget == 1_500)
        #expect(LocalAI.displayName == "本机")

        defaults.set(LocalEngine.open.rawValue, forKey: LocalAI.engineKey)
        defaults.set("mlx-community/not-a-model", forKey: LocalAI.openModelKey)
        #expect(LocalAI.openModel == .qwen3_4b)
        if OpenModelStore.readyFolder(for: .qwen3_4b) == nil {
            #expect(!LocalAI.status.isAvailable)
            #expect(LocalAI.characterBudget == 1_500)
        }
    }
}

/// Downloads an open model into the simulator and runs the app's real prompts on messy
/// speech. Off by default (gigabytes of download); run with
/// TEST_RUNNER_RAMBLE_OPEN_MODEL=<repo id> and TEST_RUNNER_RAMBLE_OPEN_REPORT=/path/report.txt.
struct OpenModelEvaluationTests {
    nonisolated static let environment = ProcessInfo.processInfo.environment

    static let organizeSamples = [
        "嗯那个今天师傅来看了一下，就是说墙面要等干透才能刷漆，大概要一周。然后下周三可以开始铺砖，呃，记得提前把瓷砖搬上楼",
        "呃就是体检报告出来了，然后那个甘油三酯有点高，二点一，医生说嗯注意饮食，三个月以后再来复查一下血脂",
        "在语音输出的内容的地方设计一个这个X之类的就是可以一键删除内容的功能尤其是那个重说的时候这个有可能这个东西之前说的就不用了还需要一个一个删不方便设计一个一键删除的东西",
    ]
    static let captureSamples = [
        "呃中午吃饭花了三十五，然后那个信用卡十五号要还两千一百八，嗯护照明年三月到期",
        "装修那边师傅说水泥要养护七天，下周三可以铺砖，然后今天买瓷砖花了三千二",
        "添加一个笔记就是点中平台短句已经上传好了呃然后有空的时候跟平台沟通一下款项的问题。",
        "呃，今天那个。铺车暖气的费用和购买瓷砖的费用一共花了82,000块钱。",
        "张三还欠我两千块，还欠装修师傅三千工钱月底给",
    ]

    @MainActor
    @Test(.enabled(if: environment["RAMBLE_OPEN_MODEL"] != nil), .timeLimit(.minutes(60)))
    func tidiesMessySpeech() async throws {
        let id = try #require(Self.environment["RAMBLE_OPEN_MODEL"])
        let model = try #require(OpenModel.find(id))
        let defaults = UserDefaults.standard
        let keys = [AISettings.modeKey, LocalAI.engineKey, LocalAI.openModelKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        defaults.set(AIMode.onDevice.rawValue, forKey: AISettings.modeKey)
        defaults.set(LocalEngine.open.rawValue, forKey: LocalAI.engineKey)
        defaults.set(model.id, forKey: LocalAI.openModelKey)

        let store = OpenModelStore.shared
        let checkStarted = ContinuousClock.now
        if OpenModelStore.readyFolder(for: model) == nil {
            store.download(model)
            while true {
                try await Task.sleep(for: .seconds(2))
                switch store.status(of: model) {
                case .ready: break
                case .failed(let message): Issue.record("download failed: \(message)"); return
                default: continue
                }
                break
            }
        }
        #expect(LocalAI.status.isAvailable)

        var report = "MODEL \(model.id)\nDOWNLOAD+CHECK \(ContinuousClock.now - checkStarted)\n"
        let now = Date.now
        for sample in Self.organizeSamples {
            let started = ContinuousClock.now
            let (organized, source) = try await NoteOrganizer.organize(sample, noteTitle: "装修记录", now: now)
            report += "\nORGANIZE \(ContinuousClock.now - started) \(source.label)\nIN:  \(sample)\nOUT: \(organized.cleanedText)\n"
            report += organized.reminders.map { "  ⏰ \($0.title) \($0.date) \($0.time) 「\($0.quote)」" }.joined(separator: "\n") + "\n"
            #expect(!organized.cleanedText.isEmpty)
            #expect(!FillerCleaner.hasFiller(organized.cleanedText))
        }
        let context = CaptureContext(now: now, timeZone: .current, baseCurrency: "CNY",
                                     expenseCategories: ["餐饮", "交通", "购物", "居住", "医疗", "其他"], incomeCategories: ["工资"],
                                     accounts: [("现金", "cash"), ("储蓄卡", "debitCard"), ("信用卡", "creditCard"), ("电子钱包", "eWallet")],
                                     existingNotes: ["装修记录"])
        for sample in Self.captureSamples {
            let started = ContinuousClock.now
            let outcome = try await CaptureEngine.parse(sample, context: context)
            report += "\nCAPTURE \(ContinuousClock.now - started) \(outcome.source.label)\nIN:  \(sample)\n"
            for item in outcome.capture.items {
                report += "  [\(item.type)] \(item.title) amount=\(item.amount) date=\(item.date) cat=\(item.category) who=\(item.counterparty) note=\(item.note) quote=\(item.quote)\n"
            }
            #expect(!outcome.capture.items.isEmpty)
        }
        print(report)
        if let path = Self.environment["RAMBLE_OPEN_REPORT"] {
            // On a phone, a bare file name lands in the app's Documents folder for copying back.
            let url = path.hasPrefix("/") ? URL(filePath: path) : URL.documentsDirectory.appending(path: path)
            try? report.write(to: url, atomically: true, encoding: .utf8)
        }
        await LocalAI.releaseMemory()
    }
}

struct OpenCaptureConversionTests {
    /// Tuesday 2026-10-13.
    private let now = DraftParsing.date("2026-10-13", time: "12:30")!

    private func parse(_ input: String, _ items: [OpenCaptureItem]) -> [ParsedItem] {
        OpenCapture(items: items).parsed(input: input, now: now).items
    }

    /// Qwen3 4B filed lunch as a bill once its example no longer matched the input.
    @Test func theVerbDecidesSpentOrDue() {
        let items = parse("呃中午吃饭花了三十五，然后那个信用卡十五号要还两千一百八", [
            OpenCaptureItem(type: "bill", title: "吃饭", amount: "35", when: "中午", category: "餐饮"),
            OpenCaptureItem(type: "expense", title: "信用卡还款", amount: "2180", when: "十五号", category: ""),
        ])
        #expect(items.map(\.type) == ["expense", "bill"])
        #expect(items[1].billKind == BillKind.creditCard.rawValue)
        #expect(OpenCapture.moneyType("bill", clause: "房租月底要交三千五") == "bill")
        #expect(OpenCapture.moneyType("expense", clause: "打车二十八") == "expense")
    }

    /// Qwen3 4B named the note after its content and put the notebook's name in the category.
    @Test func aNoteTakesTheNameFromItsCategory() {
        let items = parse("装修那边师傅说水泥要养护七天，下周三可以铺砖，然后今天买瓷砖花了三千二", [
            OpenCaptureItem(type: "expense", title: "买瓷砖", amount: "3200", when: "今天", category: "购物"),
            OpenCaptureItem(type: "note", title: "水泥养护", amount: "", when: "", category: "装修记录"),
            OpenCaptureItem(type: "task", title: "铺砖", amount: "", when: "下周三", category: ""),
        ])
        #expect(items[1].title == "装修记录")
        #expect(items[1].category.isEmpty)
        #expect(items[1].note.hasPrefix("装修那边师傅说"))
        #expect(items[0].category == "购物")
        #expect(items[2].quote == "下周三可以铺砖")
    }

    /// The cases the phone got wrong on the first run.
    @Test func lunchCardAndPassport() {
        let items = parse("呃中午吃饭花了三十五，然后那个信用卡十五号要还两千一百八，嗯护照明年三月到期", [
            OpenCaptureItem(type: "expense", title: "午餐", amount: "35", when: "中午", category: "餐饮"),
            OpenCaptureItem(type: "bill", title: "信用卡还款 2180 CNY (2026-10-15)", amount: "2180", when: "十五号", category: ""),
            OpenCaptureItem(type: "expiry", title: "护照", amount: "", when: "明年三月", category: ""),
        ])
        #expect(items[0].date.isEmpty)
        #expect(items[1].title == "信用卡还款")
        #expect(items[1].billKind == "creditCard")
        #expect(items[1].date == "2026-10-15")
        #expect(items[1].repeatFrequency == "monthly")
        #expect(items[1].repeatMonthDay == 15)
        #expect(items[2].expiryKind == "document")
        #expect(items[2].date == "2027-03-01")
        #expect(items[2].dateIsApproximate)
        #expect(items[2].reminderDaysBefore == [90, 30, 7])
    }

    @Test func renovationNoteTaskAndExpense() {
        let items = parse("装修那边师傅说水泥要养护七天，下周三可以铺砖，然后今天买瓷砖花了三千二", [
            OpenCaptureItem(type: "note", title: "装修记录", amount: "", when: "", category: ""),
            OpenCaptureItem(type: "task", title: "铺砖", amount: "", when: "下周三", category: ""),
            OpenCaptureItem(type: "expense", title: "瓷砖", amount: "3200", when: "今天", category: "居住"),
        ])
        #expect(items[0].note.contains("下周三可以铺砖"))
        #expect(!items[0].note.contains("然后"))
        #expect(items[1].date == "2026-10-21")
        #expect(items[1].quote == "下周三可以铺砖")
        #expect(items[0].note.contains(items[1].quote))
        #expect(items[2].date == "2026-10-13")
    }

    @Test func onlyOneNotePerCapture() {
        let items = parse("装修那边师傅说水泥要养护七天，下周三可以铺砖", [
            OpenCaptureItem(type: "note", title: "装修记录", amount: "", when: "", category: ""),
            OpenCaptureItem(type: "task", title: "铺砖", amount: "", when: "下周三", category: ""),
            OpenCaptureItem(type: "note", title: "水泥养护七天", amount: "", when: "", category: ""),
        ])
        #expect(items.map(\.type) == ["note", "task"])
        #expect(items[0].title == "装修记录")
    }

    @Test func compactInstructionsAreShort() {
        let context = CaptureContext(now: now, timeZone: .current, baseCurrency: "CNY", expenseCategories: ["餐饮", "交通"],
                                     incomeCategories: ["工资"], accounts: [("现金", "cash")], existingNotes: ["装修记录"])
        #expect(context.compactInstructions.count < context.instructions.count / 3)
        #expect(context.compactInstructions.contains("装修记录"))
        #expect(context.compactInstructions.contains("餐饮"))
    }

    @Test func titlesAndKindsByRule() {
        #expect(OpenCapture.cleanTitle("护照 (到期: 2027-03-31)") == "护照")
        #expect(OpenCapture.cleanTitle("话费 98元") == "话费")
        #expect(OpenCapture.billKind(for: "房租") == "rent")
        #expect(OpenCapture.billKind(for: "视频会员续费") == "subscription")
        #expect(OpenCapture.billKind(for: "某某") == "other")
        #expect(OpenCapture.expiryKind(for: "车险") == "insurance")
    }

    @Test func remindersWithoutTimeWordsUseTheirSentence() {
        let raw = OpenOrganizedNote(cleanedText: "三个月以后再来复查一下血脂。", reminders: [
            OpenReminder(quote: "三个月以后再来复查一下血脂。", title: "复查血脂", when: ""),
        ])
        let polished = NoteOrganizer.polished(raw.organized(noteTitle: "体检"), original: "嗯三个月以后再来复查一下血脂", now: now)
        #expect(polished.reminders.first?.date == "2027-01-13")
    }
}

/// What Qwen3 4B returns for real dictation (patched library, so the same every time), and what
/// the app makes of it.
struct OpenCaptureFromDictationTests {
    /// Wednesday 14 October 2026, 19:40.
    private let now = DraftParsing.date("2026-10-14", time: "19:40")!

    private func parse(_ input: String, _ items: [OpenCaptureItem]) -> [ParsedItem] {
        OpenCapture(items: items).parsed(input: input, now: now).items
    }

    @Test func aNoteSaidAsANote() {
        let input = "添加一个笔记就是点中平台短句已经上传好了呃然后有空的时候跟平台沟通一下款项的问题。"
        let items = parse(input, [OpenCaptureItem(type: "note", title: "平台款项沟通", amount: "", when: "", category: "")])
        #expect(items.count == 1 && items[0].title == "平台款项沟通")
        #expect(items[0].note.hasPrefix("点中平台短句已经上传好了"))
        // A model that names it after its type gets a name from what was said.
        let unnamed = parse(input, [OpenCaptureItem(type: "note", title: "note", amount: "", when: "", category: "")])
        #expect(unnamed[0].title == "点中平台短句已经上传")
    }

    @Test func aFeeIsntDatedByTheAppointment() {
        let items = parse("呃明天下午三点要去医院复查血脂然后挂号费花了五十", [
            OpenCaptureItem(type: "expense", title: "挂号费", amount: "50", when: "明天下午三点", category: "医疗"),
            OpenCaptureItem(type: "note", title: "体检复查", amount: "", when: "明天下午三点", category: ""),
        ])
        #expect(items[0].type == "expense" && items[0].date.isEmpty)
        let task = items.first { $0.type == "task" }
        #expect(task?.title == "去医院复查血脂" && task?.date == "2026-10-15" && task?.time == "15:00")
    }

    @Test func aStepInsideANoteBecomesATask() {
        let items = parse("装修那边师傅说水泥要养护七天，下周三可以铺砖，然后今天买瓷砖花了三千二", [
            OpenCaptureItem(type: "note", title: "装修", amount: "", when: "水泥要养护七天，下周三可以铺砖", category: ""),
            OpenCaptureItem(type: "expense", title: "买瓷砖", amount: "3200", when: "今天", category: "装修"),
        ])
        #expect(items.map(\.type) == ["note", "expense", "task"])
        #expect(items[1].date == "2026-10-14")
        #expect(items[2].title == "铺砖" && items[2].date == "2026-10-21" && items[2].quote == "下周三可以铺砖")
    }

    @Test func placeholders() {
        #expect(OpenCapture.isPlaceholder("note") && OpenCapture.isPlaceholder("笔记") && OpenCapture.isPlaceholder("x"))
        #expect(!OpenCapture.isPlaceholder("装修记录") && !OpenCapture.isPlaceholder("午餐"))
        #expect(NoteCommands.withoutCaptureCommand("记一下孩子学校老师说下周一要交春游的钱") == "孩子学校老师说下周一要交春游的钱")
        #expect(NoteCommands.withoutCaptureCommand("记录一下") == "记录一下")
    }

    /// Words that only say which note it goes in pick the note; they aren't kept in it.
    @Test func destinationWordsLeaveTheNote() {
        let strip = NoteCommands.withoutCaptureCommand
        #expect(strip("在装修这个笔记条目下加一条：检查那个开关，是不是在插排的上方。") == "检查那个开关，是不是在插排的上方。")
        #expect(strip("往装修笔记里记一下，瓷砖到了，一共42箱") == "瓷砖到了，一共42箱")
        #expect(strip("在装修里加一条：师傅下周三来铺砖") == "师傅下周三来铺砖")
        #expect(strip("装修笔记加一条：水电验收通过") == "水电验收通过")
        #expect(strip("给孩子的笔记记一下，老师说周一开家长会") == "老师说周一开家长会")
        #expect(strip("记到装修里：卫生间要做闭水试验") == "卫生间要做闭水试验")
        #expect(strip("卫生间要做闭水试验，记到装修笔记里") == "卫生间要做闭水试验。")
        #expect(strip("记一下，在装修笔记下加一条：插座要多留两个") == "插座要多留两个")
    }

    /// Sentences that only look a little like it stay whole.
    @Test func everydaySentencesStayWhole() {
        let strip = NoteCommands.withoutCaptureCommand
        for text in ["在公司楼下记得买咖啡", "我的笔记写得很乱", "在超市买了牛奶和鸡蛋", "在家等快递", "到时候记得带身份证",
                     "笔记本电脑加了内存条", "在装修笔记下加检查开关"] {
            #expect(strip(text) == text, "\(text)")
        }
    }

    /// Whichever model wrote the note, the destination words come out.
    @Test func captureResultsLoseDestinationWords() {
        var note = ParsedItem()
        note.type = "note"; note.title = "装修"; note.note = "在装修这个笔记条目下加一条：检查那个开关，是不是在插排的上方。"
        var task = ParsedItem()
        task.type = "task"; task.title = "在装修笔记下加一条：买插座"
        let cleaned = CaptureEngine.withoutDestinationWords(ParsedCapture(items: [note, task]))
        #expect(cleaned.items[0].note == "检查那个开关，是不是在插排的上方。")
        #expect(cleaned.items[1].title == "在装修笔记下加一条：买插座")  // only a note's text is changed
    }
}
