import SwiftUI

/// Speech language, and which engine turns speech into text.
struct SpeechSettingsView: View {
    @AppStorage(SpeechSettings.languageKey) private var languageRaw = SpeechLanguage.system.rawValue
    @AppStorage(SpeechSettings.engineKey) private var engineRaw = SpeechEngineKind.apple.rawValue
    @AppStorage(SpeechSettings.modelKey) private var modelID = SpeechModel.qwen3_0_6b.id
    @State private var store = SpeechModelStore.shared
    @State private var pendingDelete: SpeechModel?
    @State private var confirmsLegacyDelete = false

    var body: some View {
        Form {
            Section {
                Picker("说话语言", selection: $languageRaw) {
                    ForEach(SpeechLanguage.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } footer: {
                Text("录音时按这个语言识别。中文里夹几个英文词通常也能认出来。")
            }

            Section {
                Picker("识别方式", selection: $engineRaw) {
                    ForEach(SpeechEngineKind.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("识别方式")
            } footer: {
                Text(engineFooter)
            }

            if engineRaw == SpeechEngineKind.qwen.rawValue {
                Section {
                    if SpeechModelEngine.isSupported {
                        ForEach(SpeechModel.all) { model in
                            modelRow(model)
                        }
                    } else {
                        Label("模拟器里不能运行语音模型，请在 iPhone 上使用。", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(ModuleColor.warning)
                    }
                } header: {
                    Text("语音模型")
                } footer: {
                    Text("阿里通义千问 Qwen3-ASR（Apache 2.0 开源许可），通过苹果的 MLX 框架在手机上运行，从 Hugging Face 下载，之后完全离线，录音不离开手机。只在 Wi‑Fi 下下载，没连 Wi‑Fi 时会等连上再继续。下载时可以锁屏或切到别的 App，下载完回到这里会自动检查一次能否运行。")
                }
            }

            if store.legacyBytes > 0 {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("旧版 Whisper 模型")
                            Text("已不再使用，可以删除")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: store.legacyBytes, countStyle: .file))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button("删除", systemImage: "trash", role: .destructive) { confirmsLegacyDelete = true }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                            .padding(.leading, 8)
                    }
                }
            }
        }
        .navigationTitle("语音识别")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.refresh() }
        .deletionAlert(pendingDelete.map { String(localized: "删除「\($0.title)」？") } ?? "", item: $pendingDelete) { model in
            Button("删除，释放 \(store.freedText(model))", role: .destructive) { store.delete(model) }
        } message: { _ in
            Text("删除后会改用 iPhone 自带的识别，需要时可以再下载。")
        }
        .alert("删除旧版 Whisper 模型？", isPresented: $confirmsLegacyDelete) {
            Button("删除，释放 \(ByteCountFormatter.string(fromByteCount: store.legacyBytes, countStyle: .file))", role: .destructive) {
                store.deleteLegacyWhisper()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这个版本改用识别更准的 Qwen3-ASR，Whisper 已不再使用。")
        }
    }

    private var engineFooter: String {
        if engineRaw == SpeechEngineKind.apple.rawValue {
            return String(localized: "不用下载，边说边出字，录音不离开手机。")
        }
        guard SpeechModelEngine.isSupported else { return String(localized: "模拟器里继续用 iPhone 自带的识别。") }
        let selected = SpeechModel.find(modelID) ?? .qwen3_0_6b
        return store.status(of: selected) == .ready
            ? String(localized: "边说边出字，说完后整段再识别一遍。中文、口音和嘈杂环境下比自带的准，还会自动加标点。")
            : String(localized: "选中的模型还没下载好，暂时继续用 iPhone 自带的识别。")
    }

    @ViewBuilder
    private func modelRow(_ model: SpeechModel) -> some View {
        let status = store.status(of: model)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Button {
                    modelID = model.id
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: modelID == model.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(modelID == model.id ? Color.accentColor : Color.secondary)
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
                statusControl(model, status: status)
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
    private func statusControl(_ model: SpeechModel, status: SpeechModelStore.Status) -> some View {
        switch status {
        case .notDownloaded, .failed:
            Button("下载") {
                modelID = model.id
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
}
