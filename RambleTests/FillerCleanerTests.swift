import Testing
@testable import Ramble

struct FillerCleanerTests {
    @Test(arguments: [
        ("嗯那个今天师傅来看了一下", "今天师傅来看了一下"),
        ("呃，然后那个，下周三可以铺砖。", "下周三可以铺砖。"),
        ("我们，嗯，下午去医院。", "我们，下午去医院。"),
        ("水泥要养护七天。然后那个，就是说，周三铺砖。", "水泥要养护七天。周三铺砖。"),
        ("Um, call the landlord, uh, on Friday.", "call the landlord, on Friday."),
        ("呃呃呃", ""),
        ("要带上成绩单，还有就是，那个，校服钱两百五要交", "要带上成绩单，还有，校服钱两百五要交"),
    ])
    func removesFiller(_ input: String, _ expected: String) {
        #expect(FillerCleaner.clean(input) == expected)
    }

    @Test(arguments: [
        "那个人说下周三来。",
        "就是这个价格，3200 元。",
        "然后去超市买了菜。",
        "这个月的房租交了。",
        "额度还剩 5000。",
        "好啊！明天见。",
    ])
    func keepsRealWords(_ text: String) {
        #expect(FillerCleaner.clean(text) == text)
        #expect(!FillerCleaner.hasFiller(text))
    }

    @Test func detectsLeftoverFiller() {
        #expect(FillerCleaner.hasFiller("呃，然后那个下周三铺砖"))
    }
}
