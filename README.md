# 随口记 Ramble

想到什么，说一句就记下。随口记把你随口说的话整理成待办、账目、账单和到期提醒、笔记。语音识别和 AI 整理都可以完全在 iPhone 上完成。

Say it once and it's kept. Ramble turns what you say into to-dos, ledger entries, bill and expiry reminders, and notes. Speech recognition and AI tidying can both run entirely on your iPhone.

<p>
<img src="docs/screenshots/6.9-zh-Hans/1-today.png" width="200" alt="今天">
<img src="docs/screenshots/6.9-zh-Hans/2-capture.png" width="200" alt="整理结果">
<img src="docs/screenshots/6.9-zh-Hans/3-ledger.png" width="200" alt="账本按分类">
<img src="docs/screenshots/6.9-en/6-notes.png" width="200" alt="Notes">
</p>

完全免费、没有内购和广告，以 MIT 许可开源。Free, no in-app purchases or ads, open source under the MIT License.

- 隐私政策 Privacy Policy：<https://hellomyworkid-tech.github.io/ramble/privacy.html>
- 联系 Contact：hellolink@icloud.com

## 功能 Features

- **一句话，自动整理**：「明天下午三点交房租 3200，中午吃饭花了 35」会变成一条待办、一个账单提醒和一笔支出，确认后才保存
- **待办**：截止时间、提醒、重复、子任务、优先级
- **账本**：多账户、多币种（自动汇率）、分类、预算、统计图表、应收应付，导入微信支付、支付宝和其他 App 的 CSV
- **账单和到期**：信用卡、房租、订阅、证件、保险、合同，到期前提醒
- **笔记**：按时间追加的记录，AI 理顺语句、标重点、给某句话设提醒，照片和文件里的字也能搜索
- **AI 读文件**：体检报告、合同、保修卡、发票，在手机上识别文字后总结要点，并建议复查、续期等提醒
- **问一问、周报月报**：「这个月吃饭花了多少」，再接着问「上个月呢」，数字都在手机上算
- **少打字的入口**：从微信、相册、Safari 分享给随口记就接着整理；Apple Pay 付款后自动记一笔；在系统搜索里找笔记、待办和账单
- **其他**：iCloud 同步（用户自己的私有数据库）、小组件、Siri 和快捷指令、面容 ID 应用锁、每天自动备份和恢复、简体中文和英文界面

## AI 和隐私 AI and privacy

开发者没有任何服务器。整理用哪个模型由用户选：

| | 在哪运行 | 说明 |
|---|---|---|
| Apple Intelligence | iPhone | 系统自带，支持的机型才有 |
| 通义千问 Qwen3 4B / 1.7B | iPhone（MLX） | 从 Hugging Face 下载的开源模型（Apache 2.0），需要 iOS 27 |
| Claude、ChatGPT、Gemini、任何兼容 OpenAI 的接口 | 云端 | 用户自己的 API Key，文字从手机直接发给服务商，第一次使用前征得同意 |

语音识别用 iPhone 自带的 SpeechAnalyzer，或下载的 Qwen3-ASR 0.6B / 1.7B（MLX，在手机上运行）。

The developer runs no servers. Tidying uses Apple Intelligence, a downloaded open-source model running on the iPhone with MLX, or a cloud model with the user's own API key, sent straight from the phone to the provider after consent.

## 编译 Building

需要 Xcode 27.2 或更新版本，App 最低支持 iOS 26，只支持 iPhone。依赖用 Swift Package Manager，第一次编译时自动下载。

Requires Xcode 27.2 or later. The app targets iOS 26+, iPhone only. Swift packages resolve on the first build.

从零开始，在模拟器上跑起来（第一次要编译 MLX 和 swift-syntax，几分钟）：

```bash
git clone https://github.com/hellomyworkid-tech/ramble.git
cd ramble
scripts/build.sh sim -sampleData
```

`scripts/build.sh` 把编译需要的设置都带上了，Xcode 更新后常见的两个问题也由它处理（下面有说明）。不带参数运行可以看全部命令：

| 命令 | 做什么 |
|---|---|
| `sim` | 编译 Debug 版，装到模拟器并打开，后面的参数传给 App |
| `phone` | 编译 Release 版，装到连着的 iPhone，不打开 |
| `test`、`uitest` | 单元测试、界面测试 |
| `archive`、`upload` | 归档；归档并上传到 App Store Connect |
| `doctor` | 检查 Xcode 和 Metal 工具链 |

要装到自己的 iPhone：

1. 打开 `Ramble.xcodeproj`，在五个 target（Ramble、RambleWidgets、RambleShare、RambleTests、RambleUITests）的 Signing & Capabilities 里把 Team 换成你自己的，并把这些标识换成你自己的（它们只能属于一个开发者账号）：
   - Bundle ID：`com.zengji.suikouji`、`com.zengji.suikouji.widgets`、`com.zengji.suikouji.share`、`com.zengji.suikouji.tests`、`com.zengji.suikouji.uitests`
   - App Group：`group.com.zengji.suikouji`（`Config/*.entitlements`、`RambleShared/WidgetShared.swift`、`ShareInbox/ShareInbox.swift`）
   - iCloud 容器：`iCloud.com.zengji.suikouji`（`Config/Ramble.entitlements`、`Ramble/Services/CloudSync.swift`）
   - 上传用的 Team：`scripts/ExportOptions.plist`
2. 运行 `scripts/build.sh phone`。本机开源模型需要 iPhone 的 GPU，在模拟器里不能用；日常使用建议装 Release 版，Debug 版的 MLX 慢很多。

Xcode 更新后编译失败，多半是这两个原因：

- **「missing Metal Toolchain」**：MLX 要编译 Metal 着色器，这个组件有时要重新下载（800 多 MB）。脚本会先问你再下载，也可以自己运行 `xcodebuild -downloadComponent MetalToolchain`。
- **MLXHuggingFaceMacros「Unable to resolve Swift module dependency」**：预编译的 swift-syntax 只能配一个版本的编译器。脚本编译时不用预编译包（`-IDEPackageEnablePrebuilts=NO`），Xcode 版本变化时清掉旧版留下的缓存。直接在 Xcode 里编译碰到这个错误时，先运行一次 `scripts/build.sh sim`。

iCloud 同步：开发版用 CloudKit 的 Development 环境。要发布时，先用 Debug 版带启动参数 `-initializeCloudKitSchema` 运行一次，把所有记录类型建到 Development 环境，再在 [CloudKit Console](https://icloud.developer.apple.com) 部署到 Production。

## 测试 Tests

```bash
scripts/build.sh test    # 单元测试
scripts/build.sh uitest  # 界面测试，约 2 分钟
```

测试默认按简体中文环境写（解析的是中文口语）。语音模型的端到端测试需要在真机上、先下载好模型才会运行。界面测试走一遍启动、记一笔、分享进来的文字、点提醒通知、打开照片、账本按分类、问一问，用内存里的示例数据，不改模拟器里已有的记录。

Debug 版的启动参数：`-sampleData`（载入示例数据）、`-inMemoryStore`（数据只放内存）、`-mockAI`（不用模型，返回固定的整理结果）、`-startTab ledger`（打开某个标签页）、`-openNote 装修记录`、`-openAsk`、`-openLink ramble://…`、`-debugCaptureText …`（预填「记一下」）、`-testReminder 待办名称`（几秒后发这条待办的提醒）、`-testShare 这段话`、`-testShareFile 文件内容`（当作刚从分享面板收到）、`-testLongNote`（「装修记录」多 30 条记录，页面能滚动）。

商店截图用 `scripts/screenshots.sh` 重拍（中英文，6.9 和 6.3 英寸），放在 `docs/screenshots/`。先运行一次 `scripts/build.sh sim`。

## 目录 Layout

| 目录 | 内容 |
|---|---|
| `Ramble/App` | 入口、根视图、路由、Siri 和快捷指令、应用锁 |
| `Ramble/AI` | 整理（规则 + 模型）、提示词、Apple 模型和开源模型、云端客户端、问一问 |
| `Ramble/Speech` | 录音、SpeechAnalyzer、Qwen3-ASR |
| `Ramble/Models` | SwiftData 模型 |
| `Ramble/Services` | 查询、报告、同步、备份、CSV、汇率、小组件数据 |
| `Ramble/Features` | 各个页面 |
| `RambleWidgets`、`RambleShared` | 小组件，以及 App 和小组件共用的代码 |
| `RambleShare`、`ShareInbox` | 分享扩展，以及它和 App 交接内容的文件夹 |
| `Vendor` | 打了补丁的 mlx-swift-lm 和 mlx-audio-swift（补丁见各自的 `RAMBLE-PATCHES.md`） |
| `RambleTests`、`RambleUITests` | 单元测试、界面测试 |
| `docs` | 需求和设计说明（中文）、App Store 资料、截图 |
| `website` | 隐私政策和支持页的生成脚本（生成的网页发布在 `gh-pages` 分支） |
| `scripts` | `build.sh`：编译、测试、上传；`screenshots.sh`：重拍商店截图；`make_licenses.py`：生成 App 里的「开源许可」页 |

## 许可 License

随口记以 [MIT 许可](LICENSE) 发布。App 里用到的第三方开源软件及其许可见「设置 › 关于 › 开源许可」，或 [`Ramble/Resources/Legal/licenses.md`](Ramble/Resources/Legal/licenses.md)。下载的模型（Qwen3、Qwen3-ASR）不随 App 分发，采用 Apache 2.0 许可。

Ramble is released under the [MIT License](LICENSE). Third-party licenses are listed in the app (Settings › About › Open-Source Licenses) and in [`Ramble/Resources/Legal/licenses.md`](Ramble/Resources/Legal/licenses.md).

欢迎提 issue 和 pull request。Issues and pull requests are welcome.
