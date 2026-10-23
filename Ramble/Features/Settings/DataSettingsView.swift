import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Backups, the ledger as CSV, and entries from other apps.
struct DataSettingsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("backup.includesAttachments") private var includesAttachments = true
    @State private var exportDocument: ExportDocument?
    @State private var exportName = ""
    @State private var isPreparing = false
    @State private var isPickingBackup = false
    @State private var pendingRestore: BackupFile?
    @State private var message: String?
    @State private var attachmentBytes: Int64 = 0

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $includesAttachments) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("包含照片和文件")
                        if attachmentBytes > 0 {
                            Text("约 \(ByteCountFormatter.string(fromByteCount: attachmentBytes, countStyle: .file))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button {
                    exportBackup()
                } label: {
                    Label("导出备份", systemImage: "square.and.arrow.up")
                }
                .disabled(isPreparing)
                Button {
                    isPickingBackup = true
                } label: {
                    Label("从备份恢复", systemImage: "arrow.counterclockwise")
                }
            } header: {
                Text("完整备份")
            } footer: {
                Text("待办、账本、账单、到期、笔记和设置里的账户、分类、预算都在一个文件里，可以存到「文件」或 iCloud 云盘。换手机或重装后用「从备份恢复」找回。")
            }

            Section {
                Button {
                    exportCSV()
                } label: {
                    Label("导出账目为 CSV", systemImage: "tablecells")
                }
                NavigationLink {
                    CSVImportView()
                } label: {
                    Label("从其他 App 导入账目", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("账本表格")
            } footer: {
                Text("CSV 可以用 Excel、Numbers 打开。导入支持其他记账 App 导出的 CSV，以及微信支付、支付宝的账单文件。")
            }
        }
        .navigationTitle("备份与导入导出")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { attachmentBytes = Backup.attachmentBytes(in: context) }
        .overlay {
            if isPreparing {
                ProgressView("正在准备…")
                    .padding(24)
                    .background(.regularMaterial, in: .rect(cornerRadius: 16))
            }
        }
        .fileExporter(isPresented: exportBinding, document: exportDocument,
                      contentType: exportDocument?.contentType ?? .json, defaultFilename: exportName) { result in
            if case .failure(let error) = result { message = error.localizedDescription }
            exportDocument = nil
        }
        .fileImporter(isPresented: $isPickingBackup, allowedContentTypes: [.json]) { result in
            pickBackup(result)
        }
        .confirmationDialog(restoreTitle, isPresented: restoreBinding, titleVisibility: .visible, presenting: pendingRestore) { file in
            Button("替换为这个备份", role: .destructive) { restore(file) }
        } message: { file in
            let when = file.createdAt.formatted(date: .abbreviated, time: .shortened)
            Text(String(localized: "备份于 \(when)，含 \(file.summary)。手机上现在的全部数据会被替换，不能撤销。")
                 + (SyncMonitor.shared.isActive ? String(localized: "开着 iCloud 同步，你其他设备上的数据也会一起换成这个备份。") : ""))
        }
        .alert("提示", isPresented: messageBinding) {
            Button("好") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    // MARK: Actions

    private func exportBackup() {
        isPreparing = true
        Task {
            // Let the spinner show before the encoding work starts.
            try? await Task.sleep(for: .milliseconds(50))
            do {
                let file = try Backup.make(from: context, includeAttachments: includesAttachments)
                exportName = Backup.fileName()
                exportDocument = ExportDocument(data: try Backup.encoder().encode(file), contentType: .json)
            } catch {
                message = error.localizedDescription
            }
            isPreparing = false
        }
    }

    private func exportCSV() {
        do {
            let entries = try context.fetch(FetchDescriptor<LedgerEntry>())
            guard !entries.isEmpty else {
                message = String(localized: "账本里还没有账目。")
                return
            }
            exportName = LedgerCSV.fileName()
            exportDocument = ExportDocument(data: LedgerCSV.export(entries), contentType: .commaSeparatedText)
        } catch {
            message = error.localizedDescription
        }
    }

    private func pickBackup(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let data = try ExportDocument.read(url)
            pendingRestore = try Backup.read(data)
        } catch {
            message = error.localizedDescription
        }
    }

    private func restore(_ file: BackupFile) {
        do {
            try Backup.restore(file, into: context)
            Task { _ = await NotificationScheduler.shared.reschedule() }
            message = String(localized: "已恢复：\(file.summary)。")
        } catch {
            message = String(localized: "恢复失败，原有数据没有改动。\(error.localizedDescription)")
        }
    }

    // MARK: Bindings

    private var restoreTitle: String { String(localized: "用这个备份替换现在的数据？") }

    private var exportBinding: Binding<Bool> {
        Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } })
    }

    private var restoreBinding: Binding<Bool> {
        Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })
    }

    private var messageBinding: Binding<Bool> {
        Binding(get: { message != nil }, set: { if !$0 { message = nil } })
    }
}

/// Bytes handed to the system's save sheet.
struct ExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json, .commaSeparatedText]
    let data: Data
    let contentType: UTType

    init(data: Data, contentType: UTType) {
        self.data = data
        self.contentType = contentType
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        contentType = configuration.contentType
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    /// Reads a file the person picked, which may sit outside the app's sandbox.
    static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }
}

/// Brings in entries from another app's CSV: guesses which column is which, lets the person fix
/// it, and shows what will be added before adding it.
struct CSVImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var isPicking = false
    @State private var fileName = ""
    @State private var table: LedgerCSV.Table?
    @State private var mapping: [LedgerCSV.Field: Int] = [:]
    @State private var options = LedgerCSV.ImportOptions()
    @State private var result: LedgerCSV.ImportResult?
    @State private var error: String?

    var body: some View {
        Form {
            if let result {
                resultSection(result)
            } else if let table {
                mappingSections(table)
            } else {
                Section {
                    Button {
                        isPicking = true
                    } label: {
                        Label("选择 CSV 文件", systemImage: "doc.badge.plus")
                    }
                } footer: {
                    Text("在其他记账 App 里导出 CSV，或在微信「我 › 服务 › 钱包 › 账单 › 常见问题 › 下载账单」、支付宝「我的 › 账单 › … › 开具交易流水证明」申请账单文件，存到「文件」后在这里选择。")
                }
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(ModuleColor.warning)
                }
            }
        }
        .navigationTitle("导入账目")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText, .text]) { picked in
            load(picked)
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func mappingSections(_ table: LedgerCSV.Table) -> some View {
        let preview = parsed(table)
        Section {
            LabeledContent("文件", value: fileName)
            LabeledContent("数据行", value: "\(table.rows.count)")
            Button("换一个文件") { isPicking = true }
        }

        Section {
            ForEach(LedgerCSV.Field.allCases) { field in
                Picker(field.title, selection: binding(for: field)) {
                    Text("不导入").tag(-1)
                    ForEach(table.header.indices, id: \.self) { index in
                        Text(table.header[index].isEmpty ? String(localized: "第 \(index + 1) 列") : table.header[index]).tag(index)
                    }
                }
            }
        } header: {
            Text("每一项对应文件里的哪一列")
        } footer: {
            Text("已按列名自动对好，不对的可以改。日期和金额必须有；没有收支类型时，金额带负号的算支出、不带的算收入，全是正数就都算支出。")
        }

        Section {
            Toggle("没有的分类自动新建", isOn: $options.createsMissingCategories)
            Toggle("跳过已经记过的", isOn: $options.skipsDuplicates)
        } footer: {
            Text(options.createsMissingCategories ? "分类按名字对应；对不上的按原名新建。" : "分类按名字对应；对不上的归入「其他」。")
        }

        Section {
            ForEach(Array(preview.rows.prefix(5).enumerated()), id: \.offset) { _, row in
                ImportPreviewRow(row: row)
            }
        } header: {
            Text("预览")
        } footer: {
            Text(previewFooter(preview))
        }

        Section {
            Button {
                runImport(preview.rows)
            } label: {
                Text("导入 \(preview.rows.count) 条")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(preview.rows.isEmpty)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    @ViewBuilder
    private func resultSection(_ result: LedgerCSV.ImportResult) -> some View {
        Section {
            Label("已导入 \(result.imported) 条账目", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if result.duplicates > 0 {
                Text("\(result.duplicates) 条之前已经记过，跳过了。")
            }
            if !result.newCategories.isEmpty {
                Text("新建了分类：\(result.newCategories.joined(separator: "、"))。可以在「设置 › 分类」里改图标和颜色。")
            }
        }
        Section {
            Button("完成") { dismiss() }
        }
    }

    // MARK: Work

    private struct Preview {
        var rows: [LedgerCSV.Row] = []
        var skipped = 0
        var unreadable = 0
    }

    private func parsed(_ table: LedgerCSV.Table) -> Preview {
        var preview = Preview()
        guard mapping[.date] != nil, mapping[.amount] != nil else { return preview }
        let signed = LedgerCSV.usesSignedAmounts(table.rows, mapping: mapping)
        for cells in table.rows {
            switch LedgerCSV.read(cells, mapping: mapping, signedAmounts: signed) {
            case .success(let row): preview.rows.append(row)
            case .failure(.skipped): preview.skipped += 1
            case .failure: preview.unreadable += 1
            }
        }
        return preview
    }

    private func previewFooter(_ preview: Preview) -> String {
        if mapping[.date] == nil || mapping[.amount] == nil {
            return String(localized: "请先选好日期和金额对应的列。")
        }
        var parts = [String(localized: "可以导入 \(preview.rows.count) 条")]
        if preview.skipped > 0 { parts.append(String(localized: "\(preview.skipped) 条不计收支或为空，跳过")) }
        if preview.unreadable > 0 { parts.append(String(localized: "\(preview.unreadable) 条日期或金额认不出")) }
        return parts.joined(separator: "，") + "。"
    }

    private func load(_ picked: Result<URL, Error>) {
        error = nil
        do {
            let url = try picked.get()
            guard let text = LedgerCSV.decode(try ExportDocument.read(url)) else {
                error = String(localized: "读不出这个文件的文字，请确认是 CSV。")
                return
            }
            guard let table = LedgerCSV.Table(LedgerCSV.rows(text)) else {
                error = String(localized: "没找到表头：需要有「日期/交易时间」和「金额」两列。")
                return
            }
            fileName = url.lastPathComponent
            self.table = table
            mapping = table.guessedMapping()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func runImport(_ rows: [LedgerCSV.Row]) {
        do {
            result = try LedgerCSV.importRows(rows, options: options, into: context)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func binding(for field: LedgerCSV.Field) -> Binding<Int> {
        Binding(get: { mapping[field] ?? -1 }, set: { mapping[field] = $0 < 0 ? nil : $0 })
    }
}

private struct ImportPreviewRow: View {
    let row: LedgerCSV.Row

    private var title: String {
        if !row.note.isEmpty { return row.note }
        if !row.subcategory.isEmpty { return row.subcategory }
        return row.category.isEmpty ? String(localized: row.kind.title) : row.category
    }

    private var detail: String {
        let categories = [row.category, row.subcategory].filter { !$0.isEmpty }.joined(separator: " › ")
        let date = row.date.formatted(date: .numeric, time: .shortened)
        return categories.isEmpty ? date : date + " · " + categories
    }

    private var amount: String {
        (row.kind == .income ? "+" : "-") + row.amount.formatted(.number.precision(.fractionLength(2)))
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(amount)
                .monospacedDigit()
                .foregroundStyle(row.kind == .income ? ModuleColor.money : Color.primary)
        }
    }
}
