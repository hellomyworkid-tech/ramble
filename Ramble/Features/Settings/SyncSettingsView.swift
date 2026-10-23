import SwiftUI

/// iCloud sync: on or off, whether this device can sync, and when it last did.
struct SyncSettingsView: View {
    @AppStorage(SyncSettings.enabledKey) private var enabled = true
    @State private var monitor = SyncMonitor.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                Toggle("用 iCloud 同步", isOn: $enabled)
                if enabled != monitor.isActive {
                    Label(enabled ? "重新打开随口记后开始同步。" : "重新打开随口记后停止同步，这台设备上的数据会保留。",
                          systemImage: "arrow.clockwise")
                        .font(.footnote)
                        .foregroundStyle(ModuleColor.warning)
                }
            } footer: {
                Text("待办、账本、账单、到期、笔记和附件，在登录同一个 Apple 账户的设备之间自动同步。数据存在你自己的 iCloud 里，我们的服务器看不到。")
            }

            if monitor.isActive {
                Section("状态") {
                    LabeledContent("iCloud 账户") {
                        Text(accountText)
                            .foregroundStyle(monitor.account == .available ? Color.green : ModuleColor.warning)
                    }
                    LabeledContent("上次同步") {
                        if monitor.isSyncing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("正在同步")
                            }
                        } else {
                            Text(monitor.lastSync.map { $0.formatted(.relative(presentation: .named)) } ?? String(localized: "还没有"))
                        }
                    }
                    if let error = monitor.lastError {
                        Label(error, systemImage: "exclamationmark.icloud")
                            .font(.footnote)
                            .foregroundStyle(ModuleColor.warning)
                    }
                    if monitor.account == .noAccount || monitor.account == .restricted {
                        Button("去系统设置登录 iCloud") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                }
            } else if let setupError = monitor.setupError, enabled {
                Section {
                    Label("这次没能连上 iCloud，先只在本机保存：\(setupError)", systemImage: "exclamationmark.icloud")
                        .font(.footnote)
                        .foregroundStyle(ModuleColor.warning)
                }
            }

            Section {
                Label("下载的本机模型、API Key 和各项设置只留在这台设备上，换设备时需要重新设置。", systemImage: "iphone")
                Label("附件（照片、文件）也会同步，会占用 iCloud 空间。", systemImage: "paperclip")
                Label("提醒在每台设备上都会响；在一台上完成，另一台会跟着取消。", systemImage: "bell")
            } header: {
                Text("说明")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .navigationTitle("iCloud 同步")
        .navigationBarTitleDisplayMode(.inline)
        .task { await monitor.refreshAccount() }
    }

    private var accountText: String {
        switch monitor.account {
        case .checking: String(localized: "检查中…")
        case .available: String(localized: "可用")
        case .noAccount: String(localized: "没有登录 iCloud")
        case .restricted: String(localized: "受限制")
        case .temporarilyUnavailable: String(localized: "暂时不可用")
        case .unknown: String(localized: "无法确定")
        }
    }
}
