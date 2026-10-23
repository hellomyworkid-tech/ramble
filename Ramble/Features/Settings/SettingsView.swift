import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(AppSettings.baseCurrencyKey) private var baseCurrency = AppSettings.defaultBaseCurrency
    @AppStorage(SpeechSettings.languageKey) private var speechLanguage = SpeechLanguage.system.rawValue
    @AppStorage(SpeechSettings.engineKey) private var speechEngine = SpeechEngineKind.apple.rawValue
    #if DEBUG
    @State private var confirmReset = false
    #endif

    var body: some View {
        Form {
            Section {
                CurrencyPicker(title: "主币种", code: $baseCurrency)
                ExchangeRateRow(baseCurrency: baseCurrency)
                NavigationLink {
                    AccountsView()
                } label: {
                    Label { Text(ScreenName.accounts) } icon: { Image(systemName: "creditcard") }
                }
                NavigationLink {
                    CategoriesView()
                } label: {
                    Label { Text(ScreenName.categories) } icon: { Image(systemName: "square.grid.2x2") }
                }
                NavigationLink {
                    BudgetsView()
                } label: {
                    Label { Text(ScreenName.budgets) } icon: { Image(systemName: "chart.pie") }
                }
            } header: {
                Text("账本")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("统计和预算都按主币种汇总，外币按记账当天的汇率换算。")
                    Link("汇率来源：Rates By Exchange Rate API", destination: ExchangeRates.attributionURL)
                }
            }

            NotificationSettingsSection()

            AppLockSettingsSection()

            Section {
                NavigationLink {
                    SyncSettingsView()
                } label: {
                    LabeledContent {
                        Text(syncSummary)
                    } label: {
                        Label("iCloud 同步", systemImage: "icloud")
                    }
                }
                NavigationLink {
                    DataSettingsView()
                } label: {
                    Label("备份与导入导出", systemImage: "externaldrive")
                }
            } header: {
                Text("数据")
            }

            Section {
                NavigationLink {
                    AISettingsView()
                } label: {
                    Label("AI 整理", systemImage: "sparkles")
                }
                NavigationLink {
                    SpeechSettingsView()
                } label: {
                    LabeledContent {
                        Text(speechSummary)
                    } label: {
                        Label("语音识别", systemImage: "waveform")
                    }
                }
                NavigationLink {
                    DownloadedModelsView()
                } label: {
                    LabeledContent {
                        Text(modelBytes > 0 ? ByteCountFormatter.string(fromByteCount: modelBytes, countStyle: .file) : String(localized: "无"))
                    } label: {
                        Label("已下载的模型", systemImage: "internaldrive")
                    }
                }
            } footer: {
                Text("AI 整理可以用本机模型，或者填自己的 Claude、ChatGPT、Gemini 等服务的 API Key。语音识别可以选中文或英文，也可以下载开源的 Qwen3-ASR 模型。")
            }

            Section("关于") {
                LabeledContent("版本", value: appVersion)
                NavigationLink {
                    PrivacyPolicyView()
                } label: {
                    Label("隐私政策", systemImage: "hand.raised")
                }
                Link(destination: AppLinks.sourceCode) {
                    Label("源代码（开源）", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                NavigationLink {
                    LicensesView()
                } label: {
                    Label("开源许可", systemImage: "doc.plaintext")
                }
                if AppLinks.hasContactEmail, let mail = URL(string: "mailto:\(AppLinks.contactEmail)") {
                    Link(destination: mail) {
                        Label("联系我们", systemImage: "envelope")
                    }
                }
            }

            #if DEBUG
            Section("开发调试") {
                Button("载入示例数据") {
                    SeedData.deleteAll(context)
                    SeedData.loadSampleData(context)
                }
                Button("清空所有数据", role: .destructive) { confirmReset = true }
            }
            .confirmationDialog("清空后只保留默认分类和账户", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("清空", role: .destructive) {
                    SeedData.deleteAll(context)
                    SeedData.seedDefaultsIfNeeded(context)
                }
            }
            #endif
        }
        .onChange(of: baseCurrency) { _, newBase in
            // Stored rates point at the old base; re-derive them for the new one.
            Task {
                await ExchangeRates.shared.refresh(base: newBase)
                ExchangeRates.shared.recalculateEntries(in: context, base: newBase)
            }
        }
        .onAppear {
            OpenModelStore.shared.refresh()
            SpeechModelStore.shared.refresh()
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成", systemImage: "checkmark", role: .confirm) { dismiss() }
            }
        }
    }

    private var syncSummary: String {
        let monitor = SyncMonitor.shared
        if !monitor.isActive { return String(localized: "已关闭") }
        if monitor.lastError != nil || monitor.account == .noAccount { return String(localized: "有问题") }
        return String(localized: "已开启")
    }

    /// Space every downloaded model takes, finished or not.
    private var modelBytes: Int64 {
        let speech = SpeechModelStore.shared
        return OpenModelStore.shared.diskBytes.values.reduce(0, +) + speech.diskBytes.values.reduce(0, +) + speech.legacyBytes
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

private struct ExchangeRateRow: View {
    let baseCurrency: String
    private var rates: ExchangeRates { .shared }

    var body: some View {
        HStack {
            Text("汇率")
            Spacer()
            if rates.isRefreshing {
                ProgressView()
            } else if let table = rates.table, table.base == baseCurrency {
                Text("\(table.updatedAt.formatted(.dateTime.month().day())) 更新")
                    .foregroundStyle(.secondary)
            } else {
                Text(rates.lastError == nil ? "未获取" : "获取失败")
                    .foregroundStyle(.secondary)
            }
            Button("刷新", systemImage: "arrow.clockwise") {
                Task { await rates.refresh(base: baseCurrency) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(rates.isRefreshing)
        }
    }
}

extension SettingsView {
    /// "中文 · 自带" style summary for the settings row.
    fileprivate var speechSummary: String {
        let language = SpeechLanguage(rawValue: speechLanguage) ?? .system
        let engine = SpeechEngineKind(rawValue: speechEngine) ?? .apple
        let languageText = language == .system ? String(localized: "跟随系统") : (language == .chinese ? String(localized: "中文") : "English")
        return languageText + " · " + (engine == .apple ? String(localized: "自带") : "Qwen3-ASR")
    }
}
