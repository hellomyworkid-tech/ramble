import SwiftData
import SwiftUI

struct ExpiryEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let item: ExpiryItem?
    var onFinish: (() -> Void)?

    @State private var name: String
    @State private var kind: ExpiryKind
    @State private var expiryDate: Date
    @State private var isDayUncertain: Bool
    @State private var renewalMonths: Int
    @State private var reminderRules: [ReminderRule]
    @State private var note: String
    @State private var photos: [DraftAttachment]
    @State private var confirmDelete = false

    private static let renewalOptions: [(months: Int, title: LocalizedStringResource)] = [
        (0, "不确定"), (12, "1 年"), (24, "2 年"), (36, "3 年"), (60, "5 年"), (120, "10 年"),
    ]

    init(item: ExpiryItem?, onFinish: (() -> Void)? = nil) {
        self.item = item
        self.onFinish = onFinish
        let kind = item?.kind ?? .document
        _name = State(initialValue: item?.name ?? "")
        _kind = State(initialValue: kind)
        _expiryDate = State(initialValue: item?.expiryDate ?? Calendar.current.date(byAdding: .year, value: 1, to: Calendar.current.startOfDay(for: .now)) ?? .now)
        _isDayUncertain = State(initialValue: item?.isDayUncertain ?? false)
        _renewalMonths = State(initialValue: item?.renewalMonths ?? 0)
        _reminderRules = State(initialValue: item?.reminderRules ?? kind.defaultReminderRules)
        _note = State(initialValue: item?.note ?? "")
        _photos = State(initialValue: DraftAttachment.drafts(from: item?.attachments))
    }

    var body: some View {
        Form {
            Section {
                TextField("名称（如 护照、车险）", text: $name)
                    .font(.headline)
                Picker("类型", selection: $kind) {
                    ForEach(ExpiryKind.allCases) { kind in
                        Label { Text(kind.title) } icon: { Image(systemName: kind.symbol) }.tag(kind)
                    }
                }
            }

            Section {
                DatePicker("到期日", selection: $expiryDate, displayedComponents: .date)
                Toggle("只确定到月份", isOn: $isDayUncertain)
                Picker("续期后有效期", selection: $renewalMonths) {
                    ForEach(Self.renewalOptions, id: \.months) { option in
                        Text(option.title).tag(option.months)
                    }
                }
                ReminderRulesField(rules: $reminderRules)
            } footer: {
                if isDayUncertain {
                    Text("会显示为「\(expiryDate.formatted(.dateTime.year().month(.wide)))」，按这个月 1 号计算提醒。")
                }
            }

            Section {
                TextField("备注（如 证件号后四位、保单号）", text: $note, axis: .vertical)
            }

            AttachmentsSection(title: "证件照片和文件", attachments: $photos, allowsDocuments: true) { item in
                guard let data = item.data else { return }
                Task {
                    let text = await AttachmentImporter.extractText(from: data, kind: item.kind, contentType: item.contentType, fileName: item.fileName)
                    if let index = photos.firstIndex(where: { $0.id == item.id }) { photos[index].recognizedText = text }
                }
            }

            if let item {
                Section {
                    if item.renewalMonths > 0 {
                        Button("已续期，到期日顺延", systemImage: "arrow.clockwise") {
                            item.renew()
                            expiryDate = item.expiryDate
                        }
                    }
                    Button("删除", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(item == nil ? "新建到期提醒" : "编辑到期提醒")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if onFinish == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", systemImage: "xmark", role: .cancel) { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", systemImage: "checkmark", role: .confirm, action: save)
                    .disabled(name.trimmed.isEmpty)
            }
        }
        .confirmationDialog("删除这个到期提醒？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let item { context.delete(item) }
                finish()
            }
        }
        .onChange(of: kind) { oldKind, newKind in
            // Follow the new kind's defaults unless the user already customised the reminders.
            if reminderRules == oldKind.defaultReminderRules {
                reminderRules = newKind.defaultReminderRules
            }
        }
    }

    private func save() {
        let calendar = Calendar.current
        var date = calendar.startOfDay(for: expiryDate)
        if isDayUncertain {
            date = date.startOfMonth(calendar: calendar)
        }
        let target = item ?? ExpiryItem(name: name.trimmed, kind: kind, expiryDate: date)
        if item == nil { context.insert(target) }
        target.name = name.trimmed
        target.kind = kind
        target.expiryDate = date
        target.isDayUncertain = isDayUncertain
        target.renewalMonths = renewalMonths
        target.reminderRules = reminderRules
        target.note = note.trimmed
        DraftAttachment.sync(photos, replacing: target.attachments, in: context) { $0.expiry = target }
        finish()
    }

    private func finish() {
        if let onFinish { onFinish() } else { dismiss() }
    }
}
