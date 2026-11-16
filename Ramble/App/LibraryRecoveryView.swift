import SwiftUI
import UniformTypeIdentifiers

/// Shows instead of the app when the library won't open: what can be done, starting with what
/// changes nothing. Whatever the choice, the files that won't open are kept.
struct LibraryRecoveryView: View {
    let failure: String

    @Environment(\.scenePhase) private var scenePhase
    @State private var library = LibraryState.shared
    @State private var isPreparing = false
    @State private var isPickingBackup = false
    @State private var confirmsStartOver = false
    @State private var pendingRestore: PendingRestore?
    @State private var message: String?
    /// The new library is ready; 好 on the message goes on to it.
    @State private var isReady = false

    private var syncIsOn: Bool { SyncSettings.isEnabled }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("记录还在手机上，只是随口记现在打不开。先不要删除 App，那样会把这些文件一起删掉。",
                          systemImage: "exclamationmark.triangle")
                }

                Section {
                    Button("再试一次", systemImage: "arrow.clockwise") { library.retry() }
                } footer: {
                    Text("手机存储空间不够时也会这样，腾出一些空间后再试。")
                }

                Section {
                    Button("导出原文件", systemImage: "square.and.arrow.up", action: exportFiles)
                        .disabled(isPreparing)
                } footer: {
                    Text("把打不开的文件存到「文件」留底。里面是你的全部记录，不要随便发给别人。")
                }

                Section {
                    NavigationLink {
                        AutoBackupsView { pendingRestore = $0 }
                    } label: {
                        Label("从自动备份恢复", systemImage: "clock.arrow.circlepath")
                    }
                    Button("从备份文件恢复", systemImage: "arrow.counterclockwise") { isPickingBackup = true }
                    Button("重新开始", systemImage: "plus.circle", role: .destructive) { confirmsStartOver = true }
                } footer: {
                    Text(syncIsOn
                         ? "iCloud 同步开着：选「重新开始」，记录会从 iCloud 同步回来。从备份恢复会关掉 iCloud 同步，免得和 iCloud 里的记录重复。打不开的文件都会移到「文件 › 我的 iPhone › 随口记」，不会删除。"
                         : "打不开的文件都会移到「文件 › 我的 iPhone › 随口记」，不会删除。")
                }

                Section {
                    DisclosureGroup("出错信息") {
                        Text(failure)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("资料库打不开了")
            .navigationBarTitleDisplayMode(.inline)
        }
        .overlay {
            if isPreparing {
                ProgressView("正在准备…")
                    .padding(24)
                    .background(.regularMaterial, in: .rect(cornerRadius: 16))
            }
        }
        .fileImporter(isPresented: $isPickingBackup, allowedContentTypes: [.zip, .json], onCompletion: pickBackup)
        .alert("重新开始？", isPresented: $confirmsStartOver) {
            Button("取消", role: .cancel) {}
            Button("重新开始", role: .destructive) { startOver() }
        } message: {
            Text(syncIsOn
                 ? "打不开的文件会移到「文件 › 我的 iPhone › 随口记」，不会删除。iCloud 里的记录会同步回来。"
                 : "打不开的文件会移到「文件 › 我的 iPhone › 随口记」，不会删除。随口记会从空白开始。")
        }
        .alert("用这个备份恢复？", isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
               presenting: pendingRestore) { backup in
            Button("取消", role: .cancel) {}
            Button("恢复") { startOver(restoring: backup) }
        } message: { backup in
            let when = backup.file.createdAt.formatted(date: .abbreviated, time: .shortened)
            Text(String(localized: "备份于 \(when)，含 \(backup.file.summary)。打不开的文件会移到「文件 › 我的 iPhone › 随口记」，不会删除。")
                 + (syncIsOn ? String(localized: "iCloud 同步会关掉，免得和 iCloud 里的记录重复。") : ""))
        }
        .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") {
                message = nil
                if isReady { library.finish() }
            }
        } message: {
            Text(message ?? "")
        }
        // The files hold everything the app lock protects.
        .onChange(of: scenePhase, initial: true) { _, phase in
            AppLock.shared.scenePhaseChanged(to: phase)
        }
    }

    private func exportFiles() {
        isPreparing = true
        Task {
            do {
                if let url = try await LibraryFiles.archive() {
                    FileExportPresenter.present(url) { _ in
                        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    }
                } else {
                    message = String(localized: "手机上没有找到资料库的文件。")
                }
            } catch {
                message = error.localizedDescription
            }
            isPreparing = false
        }
    }

    private func pickBackup(_ result: Result<URL, Error>) {
        do {
            let opened = try Backup.open(try result.get())
            pendingRestore = PendingRestore(file: opened.file, source: opened.source)
        } catch {
            message = error.localizedDescription
        }
    }

    private func startOver(restoring backup: PendingRestore? = nil) {
        do {
            if let outcome = try library.startOver(restoring: backup) {
                isReady = true
                message = outcome
            } else {
                library.finish()
            }
        } catch {
            message = error.localizedDescription
        }
    }
}
