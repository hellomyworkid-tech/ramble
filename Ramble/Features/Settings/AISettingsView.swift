import SwiftUI

struct AISettingsView: View {
    @AppStorage(AISettings.modeKey) private var modeRaw = AIMode.auto.rawValue
    @AppStorage(AISettings.providerKey) private var providerRaw = AIProvider.anthropic.rawValue
    @AppStorage(AISettings.consentKey) private var consent = false
    @AppStorage(AISettings.consentScopeKey) private var consentScope = ""
    @AppStorage(AISettings.thinkingKey) private var thinkingRaw = ThinkingSetting.auto.rawValue
    @AppStorage(LocalAI.engineKey) private var engineRaw = LocalEngine.apple.rawValue
    @AppStorage(LocalAI.openModelKey) private var openModelID = OpenModel.qwen3_4b.id
    @AppStorage(NoteTidyStyle.key) private var tidyStyleRaw = NoteTidyStyle.fluent.rawValue
    @State private var keyedProviders: Set<AIProvider> = []
    @State private var appleStatus = OnDeviceStatus.unknown
    @State private var store = OpenModelStore.shared
    @State private var pendingDelete: OpenModel?

    private var mode: AIMode { AIMode(rawValue: modeRaw) ?? .auto }

    var body: some View {
        Form {
            Section {
                Picker("处理方式", selection: $modeRaw.animation()) {
                    ForEach(AIMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text(modeFooter)
            }

            Section {
                Picker("笔记整理", selection: $tidyStyleRaw) {
                    ForEach(NoteTidyStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } footer: {
                Text(tidyStyleRaw == NoteTidyStyle.light.rawValue
                     ? "只去掉「嗯」「然后那个」之类的口头禅和重复，原话的说法不动。"
                     : "按意思把口述写成通顺的句子：补标点、去重复、理顺前后颠倒的地方，事实和数字一个不少；改得不对时自动退回只去口头禅。")
            }

            // Each mode shows only what it uses.
            if mode != .cloud {
                localSections
            }
            if mode != .onDevice {
                cloudSections
            }
        }
        .navigationTitle("AI 整理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .deletionAlert(pendingDelete.map { String(localized: "删除「\($0.title)」？") } ?? "", item: $pendingDelete) { model in
            Button("删除，释放 \(store.freedText(model))", role: .destructive) { store.delete(model) }
        } message: { model in
            Text(openModelID == model.id && engineRaw == LocalEngine.open.rawValue
                 ? "删除后本机整理会改用 Apple Intelligence（如果可用），「自动」模式下也会交给云端。需要时可以再下载。"
                 : "需要时可以再下载。")
        }
    }

    // MARK: On the phone

    @ViewBuilder
    private var localSections: some View {
        Section {
            Picker("使用", selection: $engineRaw.animation()) {
                ForEach(LocalEngine.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if engineRaw == LocalEngine.apple.rawValue {
                LabeledContent("状态") {
                    Text(appleStatus.message)
                        .foregroundStyle(appleStatus.isAvailable ? Color.green : Color.secondary)
                }
            }
        } header: {
            Text("本机模型")
        } footer: {
            Text(engineRaw == LocalEngine.apple.rawValue
                 ? "免费、不用联网，文字不会离开手机。模型较小，中文口语整理得一般，可能留下「嗯」「然后那个」。"
                 : "免费、不用联网，文字不会离开手机。下载一次后完全在手机上运行，整理效果比 Apple Intelligence 好得多。")
        }

        if engineRaw == LocalEngine.open.rawValue {
            Section {
                if LocalAI.supportsOpenModels {
                    ForEach(OpenModel.all) { model in
                        openModelRow(model)
                    }
                } else {
                    Label(LocalAI.isSimulator ? "模拟器里不能运行开源模型，请在 iPhone 上使用。" : "开源模型需要 iOS 27 或更新的系统。",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(ModuleColor.warning)
                }
            } header: {
                Text("开源模型")
            } footer: {
                Text("阿里通义千问 Qwen（Apache 2.0 开源许可），通过苹果的 MLX 框架在手机上运行，从 Hugging Face 下载。只在 Wi‑Fi 下下载，没连 Wi‑Fi 时会等连上再继续。下载时可以锁屏或切到别的 App，下载完回到这里会自动检查一次能否运行。")
            }
        }
    }

    @ViewBuilder
    private func openModelRow(_ model: OpenModel) -> some View {
        let status = store.status(of: model)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Button {
                    openModelID = model.id
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: openModelID == model.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(openModelID == model.id ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.title)
                                .foregroundStyle(.primary)
                            Text(model.sizeText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!model.fitsThisDevice)
                Spacer()
                openModelControl(model, status: status)
            }
            Text(model.note)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !model.fitsThisDevice {
                Text("这台设备的内存不够运行它。")
                    .font(.footnote)
                    .foregroundStyle(ModuleColor.warning)
            }
            switch status {
            case .downloading(let fraction):
                ProgressView(value: fraction)
            case .checking:
                Text("下载完成，正在检查能否在这台手机上运行…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(ModuleColor.warning)
            default:
                EmptyView()
            }
            if status != .ready, store.canDelete(model) {
                LeftoverFilesRow(bytes: store.diskBytes[model.id] ?? 0) { pendingDelete = model }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func openModelControl(_ model: OpenModel, status: OpenModelStore.Status) -> some View {
        switch status {
        case .notDownloaded, .failed:
            Button("下载") {
                openModelID = model.id
                store.download(model)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!model.fitsThisDevice)
        case .downloading(let fraction):
            HStack(spacing: 8) {
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("取消", systemImage: "xmark.circle.fill") { store.cancel(model) }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.borderless)
            }
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .ready:
            DownloadedBadge { pendingDelete = model }
        }
    }

    // MARK: Cloud

    @ViewBuilder
    private var cloudSections: some View {
        Section {
            ForEach(AIProvider.allCases) { provider in
                NavigationLink {
                    ProviderSettingsView(provider: provider)
                } label: {
                    HStack {
                        Text(provider.displayName)
                        if provider.rawValue == providerRaw {
                            Text("使用中")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.12), in: .capsule)
                        }
                        Spacer()
                        Text(keyedProviders.contains(provider)
                             ? (AISettings.model(for: provider).isEmpty ? String(localized: "未选模型") : AISettings.model(for: provider))
                             : String(localized: "未设置"))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        } header: {
            Text("云端 AI（自带 API Key）")
        } footer: {
            Text("API Key 只保存在这台设备的钥匙串里。文字用你的 Key 直接发给服务商，不经过我们的服务器，费用由服务商按你的账户计算。「自定义接口」可以接 DeepSeek、通义千问、Kimi、智谱、豆包等兼容 OpenAI 格式的服务。")
        }

        Section {
            Picker("思考强度", selection: $thinkingRaw) {
                ForEach(ThinkingSetting.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("云端思考强度")
        } footer: {
            Text(thinkingFooter)
        }

        Section {
            // Read through the stored scope too, so the toggle shows false after switching provider.
            Toggle("允许把文字发送给 \(AIProvider(rawValue: providerRaw)?.displayName ?? "")",
                   isOn: Binding(get: { consent && consentScope == AISettings.consentScope },
                                 set: { AISettings.hasCloudConsent = $0 }))
        } footer: {
            Text(mode == .auto ? "关闭后只用本机模型。第一次用到云端、或换了一家服务商时，会再问你一次。"
                               : "第一次用到云端、或换了一家服务商时，会再问你一次。")
        }
    }

    private var thinkingFooter: String {
        switch ThinkingSetting(rawValue: thinkingRaw) ?? .auto {
        case .auto:
            String(localized: "按内容决定：一两句话的记账、待办直接快速出结果；很长很乱的口述和整理笔记稍微多想；读报告、合同用均衡，特别长的文件用深入。快速的结果没通过检查时，自动加强重试一次。")
        case .fast:
            String(localized: "几秒出结果，记账、待办、日常笔记足够用。")
        case .balanced:
            String(localized: "先想一想再回答：很长很乱的一段话、读合同和报告时更准。会慢一些，费用也高一些。")
        case .thorough:
            String(localized: "想得最仔细，适合复杂的长文件。可能要十几秒到一分钟，费用明显更高。")
        }
    }

    private var modeFooter: String {
        switch mode {
        case .auto: String(localized: "先用本机模型；本机不可用、或者整理得不对时，再交给选中的云端 AI（这时会慢一些）。")
        case .onDevice: String(localized: "只用本机模型，完全不联网。")
        case .cloud: String(localized: "总是交给云端 AI，理解力最强，需要联网。")
        }
    }

    private func refresh() {
        appleStatus = OnDeviceParser.status
        keyedProviders = Set(AIProvider.allCases.filter(AIKeychain.hasKey))
        store.refresh()
    }

}

struct ProviderSettingsView: View {
    let provider: AIProvider

    @AppStorage(AISettings.providerKey) private var providerRaw = AIProvider.anthropic.rawValue
    @AppStorage(AISettings.customBaseURLKey) private var baseURLText = ""
    @AppStorage(AISettings.customNameKey) private var customName = ""
    @State private var keyText = ""
    @State private var storedKeyHint: String?
    @State private var model = ""
    @State private var fetchedModels: [AIModelInfo] = []
    @State private var isChecking = false
    @State private var checkMessage: String?
    @State private var checkFailed = false

    var body: some View {
        Form {
            Section {
                if provider.rawValue == providerRaw {
                    Label("云端 AI 正在使用 \(provider.displayName)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                } else {
                    Button("改用 \(provider.displayName)") { providerRaw = provider.rawValue }
                }
            }

            if provider == .custom {
                endpointSection
            }

            Section {
                SecureField(storedKeyHint.map { String(localized: "已保存（…\($0)），输入新的可替换") } ?? provider.keyPlaceholder, text: $keyText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                HStack {
                    Button("保存并验证", action: saveAndVerify)
                        .disabled(keyText.trimmed.isEmpty || isChecking)
                    Spacer()
                    if isChecking { ProgressView() }
                }
                .buttonStyle(.borderless)
                if storedKeyHint != nil {
                    Button("重新验证 / 获取模型列表", action: verifyStored)
                        .buttonStyle(.borderless)
                        .disabled(isChecking)
                    Button("删除 Key", role: .destructive, action: deleteKey)
                        .buttonStyle(.borderless)
                }
                if let checkMessage {
                    Label(checkMessage, systemImage: checkFailed ? "xmark.octagon.fill" : "checkmark.seal.fill")
                        .foregroundStyle(checkFailed ? Color.red : Color.green)
                        .font(.footnote)
                }
            } header: {
                Text("API Key")
            } footer: {
                if let page = provider.keyPageURL {
                    Link("去 \(provider == .custom ? provider.displayName : provider.vendor) 获取 API Key", destination: page)
                } else if provider == .custom {
                    Text("在服务商的网站上创建。自己运行的 Ollama 等本地服务不需要 Key，随便填一个即可。")
                }
            }

            Section {
                Picker("模型", selection: $model) {
                    ForEach(modelOptions, id: \.self) { id in
                        Text(displayName(for: id)).tag(id)
                    }
                }
                .pickerStyle(.navigationLink)
                LabeledContent("模型 ID") {
                    TextField(provider.defaultModel.isEmpty ? String(localized: "如 deepseek-chat") : provider.defaultModel, text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .font(.callout.monospaced())
                }
            } header: {
                Text("模型")
            } footer: {
                Text(modelFooter)
            }
        }
        .navigationTitle(provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model = AISettings.model(for: provider)
            refreshKeyHint()
        }
        .onChange(of: model) { _, newValue in
            UserDefaults.standard.set(newValue.trimmed, forKey: AISettings.modelKey(provider))
        }
    }

    private var modelOptions: [String] {
        var options = provider.suggestedModels
        for info in fetchedModels where !options.contains(info.id) { options.append(info.id) }
        if !model.isEmpty, !options.contains(model) { options.insert(model, at: 0) }
        return options
    }

    private func displayName(for id: String) -> String {
        if let info = fetchedModels.first(where: { $0.id == id }), info.displayName != id {
            return "\(info.displayName)（\(id)）"
        }
        return id == provider.defaultModel ? String(localized: "\(id)（默认）") : id
    }

    private var modelFooter: String {
        switch provider {
        case .anthropic: String(localized: "默认 Claude Opus 5.5，理解力最强。想更快、更便宜可以选 Claude Haiku 5.5。")
        case .openai: String(localized: "默认 gpt-6-astra。验证 Key 后可以从你的账户获取全部可用模型。")
        case .gemini: String(localized: "默认 Gemini 3.8 Flash。想更快、更便宜可以选 Gemini 3.5 Flash-Lite。")
        case .custom: String(localized: "填服务商提供的模型名。验证 Key 后可以从接口获取可用模型列表。选能力强一些的对话模型效果更好。")
        }
    }

    /// The custom endpoint: a known service in one tap, or any address.
    @ViewBuilder
    private var endpointSection: some View {
        Section {
            Menu {
                ForEach(CustomEndpointPreset.all) { preset in
                    Button(preset.name) {
                        baseURLText = preset.baseURL
                        customName = ""
                        if model.isEmpty || !preset.suggestedModels.contains(model) { model = preset.suggestedModels.first ?? "" }
                        fetchedModels = []
                        checkMessage = nil
                    }
                }
            } label: {
                LabeledContent("常用服务") {
                    Text(CustomEndpointPreset.matching(AISettings.normalizedBaseURL(baseURLText))?.name ?? String(localized: "选择"))
                }
            }
            LabeledContent("接口地址") {
                TextField("https://api.example.com/v1", text: $baseURLText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .font(.callout.monospaced())
            }
            LabeledContent("显示名称") {
                TextField(CustomEndpointPreset.matching(AISettings.normalizedBaseURL(baseURLText))?.name ?? String(localized: "自定义接口"),
                          text: $customName)
                    .multilineTextAlignment(.trailing)
            }
            if !baseURLText.trimmed.isEmpty, AISettings.normalizedBaseURL(baseURLText) == nil {
                Label(AIError.badEndpoint.localizedDescription, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(ModuleColor.warning)
            }
        } header: {
            Text("接口")
        } footer: {
            Text("需要兼容 OpenAI 的 Chat Completions 格式（地址一般以 /v1 结尾，App 会自动加上 /chat/completions）。DeepSeek、通义千问、Kimi、智谱、豆包、硅基流动、OpenRouter 都支持，也可以填局域网里自己运行的 Ollama（http://电脑的IP:11434/v1）。")
        }
    }

    private func refreshKeyHint() {
        storedKeyHint = AIKeychain.key(for: provider).map { String($0.suffix(4)) }
    }

    private func saveAndVerify() {
        let key = keyText.trimmed
        guard !key.isEmpty else { return }
        guard AIKeychain.setKey(key, for: provider) else {
            checkFailed = true
            checkMessage = String(localized: "保存到钥匙串失败。")
            return
        }
        keyText = ""
        refreshKeyHint()
        if providerRaw != provider.rawValue, !AIKeychain.hasKey(for: AIProvider(rawValue: providerRaw) ?? .anthropic) {
            providerRaw = provider.rawValue
        }
        verify(key: key)
    }

    private func verifyStored() {
        guard let key = AIKeychain.key(for: provider) else { return }
        verify(key: key)
    }

    private func verify(key: String) {
        isChecking = true
        checkMessage = nil
        Task {
            defer { isChecking = false }
            do {
                let models = try await CloudClient(provider: provider, apiKey: key, model: model,
                                                   baseURL: provider == .custom ? AISettings.customBaseURL : nil).listModels()
                fetchedModels = models
                checkFailed = false
                checkMessage = String(localized: "Key 有效，账户里有 \(models.count) 个可用模型。")
            } catch {
                checkFailed = true
                checkMessage = error.localizedDescription
            }
        }
    }

    private func deleteKey() {
        AIKeychain.setKey(nil, for: provider)
        fetchedModels = []
        checkMessage = nil
        refreshKeyHint()
    }
}
