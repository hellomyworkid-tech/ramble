import SwiftUI

/// Every model with files on the phone, whichever setting uses it, so space can be freed
/// even after switching to Apple's model or the cloud.
struct DownloadedModelsView: View {
    @AppStorage(LocalAI.engineKey) private var engineRaw = LocalEngine.apple.rawValue
    @AppStorage(LocalAI.openModelKey) private var openModelID = OpenModel.qwen3_4b.id
    @AppStorage(SpeechSettings.engineKey) private var speechEngineRaw = SpeechEngineKind.apple.rawValue
    @AppStorage(SpeechSettings.modelKey) private var speechModelID = SpeechModel.qwen3_0_6b.id
    @State private var openStore = OpenModelStore.shared
    @State private var speechStore = SpeechModelStore.shared
    @State private var pending: PendingDelete?

    private enum PendingDelete: Identifiable {
        case open(OpenModel), speech(SpeechModel), legacyWhisper

        var id: String {
            switch self {
            case .open(let model): "open:" + model.id
            case .speech(let model): "speech:" + model.id
            case .legacyWhisper: "whisper"
            }
        }
    }

    var body: some View {
        let open = OpenModel.all.filter { (openStore.diskBytes[$0.id] ?? 0) > 0 }
        let speech = SpeechModel.all.filter { (speechStore.diskBytes[$0.id] ?? 0) > 0 }
        let legacy = speechStore.legacyBytes
        Form {
            if open.isEmpty && speech.isEmpty && legacy == 0 {
                ContentUnavailableView("没有下载的模型", systemImage: "internaldrive",
                                       description: Text("在「AI 整理」和「语音识别」里可以下载开源模型。"))
            }
            if !open.isEmpty {
                Section("AI 整理") {
                    ForEach(open) { model in
                        row(.open(model), title: model.title, bytes: openStore.diskBytes[model.id] ?? 0,
                            state: openState(model), canDelete: openStore.canDelete(model))
                    }
                }
            }
            if !speech.isEmpty || legacy > 0 {
                Section("语音识别") {
                    ForEach(speech) { model in
                        row(.speech(model), title: model.title, bytes: speechStore.diskBytes[model.id] ?? 0,
                            state: speechState(model), canDelete: speechStore.canDelete(model))
                    }
                    if legacy > 0 {
                        row(.legacyWhisper, title: String(localized: "旧版 Whisper 模型"), bytes: legacy,
                            state: (String(localized: "已不再使用，可以删除"), false), canDelete: true)
                    }
                }
            }
            if !open.isEmpty || !speech.isEmpty || legacy > 0 {
                Section {
                } footer: {
                    Text("模型不会进 iCloud 备份。删掉正在使用的模型后，AI 整理改用 Apple Intelligence 或云端，语音识别改用 iPhone 自带的；需要时可以再下载。")
                }
            }
        }
        .navigationTitle("已下载的模型")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            openStore.refresh()
            speechStore.refresh()
        }
        .deletionAlert(dialogTitle, item: $pending) { item in
            switch item {
            case .open(let model):
                Button("删除，释放 \(openStore.freedText(model))", role: .destructive) { openStore.delete(model) }
            case .speech(let model):
                Button("删除，释放 \(speechStore.freedText(model))", role: .destructive) { speechStore.delete(model) }
            case .legacyWhisper:
                Button("删除，释放 \(ByteCountFormatter.string(fromByteCount: speechStore.legacyBytes, countStyle: .file))",
                       role: .destructive) { speechStore.deleteLegacyWhisper() }
            }
        } message: { _ in
            Text("需要时可以再下载。")
        }
    }

    private func row(_ item: PendingDelete, title: String, bytes: Int64, state: (text: String, inUse: Bool),
                     canDelete: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(state.text)
                    .font(.caption)
                    .foregroundStyle(state.inUse ? Color.accentColor : Color.secondary)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("删除", systemImage: "trash", role: .destructive) { pending = item }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(canDelete ? Color.red : Color.secondary)
                .disabled(!canDelete)
                .padding(.leading, 8)
        }
    }

    private func openState(_ model: OpenModel) -> (text: String, inUse: Bool) {
        switch openStore.status(of: model) {
        case .ready:
            let inUse = engineRaw == LocalEngine.open.rawValue && openModelID == model.id
            return (inUse ? String(localized: "正在使用") : String(localized: "已下载"), inUse)
        case .downloading(let fraction):
            return (String(localized: "下载中 \(fraction.formatted(.percent.precision(.fractionLength(0))))"), false)
        case .checking:
            return (String(localized: "正在检查"), false)
        case .failed:
            return (String(localized: "下载失败，留下了部分文件"), false)
        case .notDownloaded:
            return (String(localized: "没下载完的文件"), false)
        }
    }

    private func speechState(_ model: SpeechModel) -> (text: String, inUse: Bool) {
        switch speechStore.status(of: model) {
        case .ready:
            let inUse = speechEngineRaw == SpeechEngineKind.qwen.rawValue && speechModelID == model.id
            return (inUse ? String(localized: "正在使用") : String(localized: "已下载"), inUse)
        case .downloading(let fraction):
            return (String(localized: "下载中 \(fraction.formatted(.percent.precision(.fractionLength(0))))"), false)
        case .checking:
            return (String(localized: "正在检查"), false)
        case .failed:
            return (String(localized: "下载失败，留下了部分文件"), false)
        case .notDownloaded:
            return (String(localized: "没下载完的文件"), false)
        }
    }
}

extension DownloadedModelsView {
    fileprivate var dialogTitle: String {
        switch pending {
        case .open(let model): String(localized: "删除「\(model.title)」？")
        case .speech(let model): String(localized: "删除「\(model.title)」？")
        case .legacyWhisper: String(localized: "删除旧版 Whisper 模型？")
        case nil: ""
        }
    }
}

/// "已下载" with a delete button beside it, at the end of a model row.
struct DownloadedBadge: View {
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Label("已下载", systemImage: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.green)
            Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
        }
    }
}

/// Files left by a download that stopped part-way, with a way to remove them.
struct LeftoverFilesRow: View {
    let bytes: Int64
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Text("没下载完的文件占用 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("删除", role: .destructive, action: onDelete)
                .font(.footnote)
                .buttonStyle(.borderless)
        }
    }
}
