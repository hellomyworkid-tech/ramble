import SwiftUI

/// Every Apple Pay payment recorded by itself. It takes an automation in Shortcuts,
/// which only the person can make, so this page walks them through it.
struct ApplePaySetupView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                Text("用 Apple Pay 付款后自动记一笔：金额、商家和卡片都从交易里取，不用打字，也不用 AI。")
            }

            Section {
                step(1, "新建一个快捷指令，在操作列表上方点「自动化」，往下找到「钱包」。出现「轻触任一卡片时」就对了。")
                step(2, "在下方搜索「记一笔支出」，点它加进来。")
                step(3, "点「金额」，在键盘上方那一排往左滑到「交易」并点它；再点一下这个「交易」，选「数量」。")
                step(4, "点「记一笔支出」右边的箭头。「商家」用同样的办法选「交易」里的「商家」，「卡片」选「卡片或凭证」。")
                step(5, "关掉「运行时显示」，不然每次付款都要点一下「完成」。")
                step(6, "点左上角返回。下次付款后，账本里就多了这一笔。")
                Button("打开快捷指令", systemImage: "arrow.up.forward.app") {
                    if let url = URL(string: "shortcuts://create-automation") { openURL(url) }
                }
            } header: {
                Text("在「快捷指令」里设置一次")
            } footer: {
                Text("以上是 iOS 27 的界面。iOS 26 在「自动化」页新建自动化，选「钱包」和「立即运行」，变量叫「快捷指令输入」。")
            }

            Section("记下来的是什么") {
                Text("分类和账户跟这个商家上次记的一样，所以改过一次，下次就对了。没记过的商家按名字猜分类，猜不到算「其他」。卡片名字和账户名字对得上，就记到那个账户。")
                Text("金额带外币符号时按那种货币记。")
            }

            Section("没记上的话") {
                Text("只有在实体店刷 Apple Pay 才会触发，网上和 App 里付款不会，这是系统的限制。")
                Text("在系统「设置 › App › 钱包」里打开「蜂窝数据」。有人遇到过关着时自动化不运行。")
                Text("想先试试：在快捷指令里删掉「轻触任一卡片时」，金额填个数字，点运行按钮，看账本里有没有多一笔。试完记得把它加回来。")
            }
        }
        .navigationTitle("Apple Pay 自动记账")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ number: Int, _ text: LocalizedStringResource) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number, format: .number)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.tint)
            Text(text)
        }
    }
}
