import SwiftData
import SwiftUI

struct EntryEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.baseCurrencyKey) private var baseCurrency = AppSettings.defaultBaseCurrency

    let entry: LedgerEntry?
    /// Opens the photo picker straight away to scan a receipt.
    var startsWithReceipt = false
    var onFinish: (() -> Void)?

    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query(filter: #Predicate<Account> { !$0.isArchived }, sort: \Account.sortOrder) private var accounts: [Account]

    @State private var kind: EntryKind
    @State private var amountText: String
    @State private var currencyCode: String
    @State private var rateText: String
    @State private var category: LedgerCategory?
    @State private var account: Account?
    @State private var toAccount: Account?
    @State private var date: Date
    @State private var note: String
    @State private var photos: [DraftAttachment]
    @State private var scanStatus: String?
    @State private var isScanning = false
    @State private var confirmDelete = false
    @FocusState private var amountFocused: Bool

    private var rates: ExchangeRates { .shared }

    init(entry: LedgerEntry?, startsWithReceipt: Bool = false, onFinish: (() -> Void)? = nil) {
        self.entry = entry
        self.startsWithReceipt = startsWithReceipt
        self.onFinish = onFinish
        let base = UserDefaults.standard.string(forKey: AppSettings.baseCurrencyKey) ?? AppSettings.defaultBaseCurrency
        _kind = State(initialValue: entry?.kind ?? .expense)
        _amountText = State(initialValue: entry?.amount.inputText ?? "")
        _currencyCode = State(initialValue: entry?.currencyCode ?? base)
        _rateText = State(initialValue: entry.map { $0.currencyCode == base ? "" : $0.rateToBase.rateText } ?? "")
        _category = State(initialValue: entry?.category)
        _account = State(initialValue: entry?.account)
        _toAccount = State(initialValue: entry?.toAccount)
        _date = State(initialValue: entry?.date ?? .now)
        _note = State(initialValue: entry?.note ?? "")
        _photos = State(initialValue: DraftAttachment.drafts(from: entry?.attachments))
    }

    var body: some View {
        Form {
            Section {
                Picker("类型", selection: $kind) {
                    ForEach(EntryKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                AmountField(text: $amountText, currencyCode: currencyCode, focused: $amountFocused)
                if isScanning {
                    Label("正在识别小票…", systemImage: "text.viewfinder")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let scanStatus {
                    Label(scanStatus, systemImage: "text.viewfinder")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if kind != .transfer {
                Section("分类") {
                    CategoryGrid(categories: categories.filter { $0.kind == kind.categoryKind && $0.parent == nil }, selection: $category)
                }
            }

            Section {
                if kind == .transfer {
                    accountPicker("转出账户", selection: $account)
                    accountPicker("转入账户", selection: $toAccount)
                } else {
                    accountPicker("账户", selection: $account)
                }
                DatePicker("时间", selection: $date)
                TextField("备注（如 午餐、地铁）", text: $note)
            }

            currencySection

            AttachmentsSection(title: "小票和照片", attachments: $photos, addPhotoTitle: "添加小票照片",
                               allowsDocuments: true, presentsPickerOnAppear: startsWithReceipt) { item in
                if item.kind == .image { scan(item) } else { index(item) }
            }

            if entry != nil {
                Section {
                    Button("删除这笔", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(entry == nil ? (startsWithReceipt ? "扫小票记一笔" : "记一笔") : "编辑")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if onFinish == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", systemImage: "xmark", role: .cancel) { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", systemImage: "checkmark", role: .confirm, action: save)
                    .disabled(!canSave)
            }
        }
        .confirmationDialog("删除这笔记录？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let entry { context.delete(entry) }
                finish()
            }
        }
        .onChange(of: kind) { _, newKind in
            if category?.kind != newKind.categoryKind { category = nil }
        }
        .onChange(of: account) { _, newAccount in
            if entry == nil, let newAccount { currencyCode = newAccount.currencyCode }
        }
        .onChange(of: currencyCode) { _, code in fillRate(for: code) }
        .onAppear {
            if entry == nil {
                if !startsWithReceipt { amountFocused = true }
                if account == nil { account = accounts.first }
            }
        }
        .task {
            await rates.refreshIfNeeded(base: baseCurrency)
            if rateText.isEmpty { fillRate(for: currencyCode) }
        }
    }

    // MARK: - Currency

    @ViewBuilder
    private var currencySection: some View {
        Section {
            CurrencyPicker(title: "币种", code: $currencyCode)
            if currencyCode != baseCurrency {
                LabeledContent("1 \(currencyCode) =") {
                    TextField(baseCurrency, text: $rateText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                if let amount, let rate = Decimal(userInput: rateText) {
                    LabeledContent("约合", value: (amount * rate).money(baseCurrency))
                }
            }
        } footer: {
            if currencyCode != baseCurrency {
                VStack(alignment: .leading, spacing: 4) {
                    if let table = rates.table, table.base == baseCurrency, table.rateToBase(currencyCode) != nil {
                        Text("按 \(table.updatedAt.formatted(.dateTime.month().day())) 的汇率自动换算，可以修改。")
                    } else {
                        Text("暂时拿不到 \(currencyCode) 的汇率，请手动填写。")
                    }
                    Link("汇率来源：Rates By Exchange Rate API", destination: ExchangeRates.attributionURL)
                }
            }
        }
    }

    private func fillRate(for code: String) {
        guard code != baseCurrency else {
            rateText = ""
            return
        }
        if let rate = rates.rateToBase(code, base: baseCurrency) {
            rateText = rate.rateText
        }
    }

    // MARK: - Receipt

    /// Reads a receipt photo on the device and fills only the fields still empty.
    private func scan(_ photo: DraftAttachment) {
        guard let data = photo.data else { return }
        isScanning = true
        scanStatus = nil
        Task {
            let lines = (try? await ReceiptScanner.recognizeLines(in: data)) ?? []
            if let index = photos.firstIndex(where: { $0.id == photo.id }) {
                photos[index].recognizedText = lines.joined(separator: "\n")
            }
            let info = ReceiptParser.parse(lines)
            var found: [String] = []
            if amountText.trimmed.isEmpty, let amount = info.amount {
                amountText = amount.inputText
                found.append(amount.money(currencyCode))
            }
            if note.trimmed.isEmpty, let merchant = info.merchant {
                note = merchant
                found.append(merchant)
            }
            if entry == nil, let day = info.date, !Calendar.current.isDate(day, inSameDayAs: date) {
                let time = Calendar.current.dateComponents([.hour, .minute], from: date)
                date = Calendar.current.date(bySettingHour: time.hour ?? 12, minute: time.minute ?? 0, second: 0, of: day) ?? day
                found.append(DayText.dayWithWeekday(day))
            }
            if lines.isEmpty {
                scanStatus = String(localized: "照片里没有认出文字。")
            } else if found.isEmpty {
                scanStatus = amountText.isEmpty ? String(localized: "没认出金额，请手动填写。") : String(localized: "已保存照片，金额保持你填的。")
            } else {
                scanStatus = String(localized: "已从小票识别：\(found.joined(separator: " · "))，请核对")
            }
            isScanning = false
        }
    }

    /// Reads a PDF's or text file's words for search.
    private func index(_ item: DraftAttachment) {
        guard let data = item.data else { return }
        Task {
            let text = await AttachmentImporter.extractText(from: data, kind: item.kind, contentType: item.contentType, fileName: item.fileName)
            if let index = photos.firstIndex(where: { $0.id == item.id }) { photos[index].recognizedText = text }
        }
    }

    // MARK: - Saving

    private func accountPicker(_ title: LocalizedStringResource, selection: Binding<Account?>) -> some View {
        Picker(selection: selection) {
            Text("不指定").tag(Account?.none)
            ForEach(accounts) { account in
                Text(account.name).tag(Optional(account))
            }
        } label: {
            Text(title)
        }
    }

    private var amount: Decimal? {
        guard let value = Decimal(userInput: amountText), value > 0 else { return nil }
        return value
    }

    private var canSave: Bool {
        guard amount != nil, !isScanning else { return false }
        if kind == .transfer {
            return account != nil && toAccount != nil && account != toAccount
        }
        return true
    }

    private func save() {
        guard let amount else { return }
        let target = entry ?? LedgerEntry(kind: kind, amount: amount, currencyCode: currencyCode)
        if entry == nil { context.insert(target) }
        target.kind = kind
        target.amount = amount
        target.currencyCode = currencyCode
        target.rateToBase = currencyCode == baseCurrency
            ? 1
            : (Decimal(userInput: rateText) ?? rates.rateToBase(currencyCode, base: baseCurrency) ?? 1)
        target.date = date
        target.note = note.trimmed
        target.category = kind == .transfer ? nil : category
        target.account = account
        target.toAccount = kind == .transfer ? toAccount : nil
        DraftAttachment.sync(photos, replacing: target.attachments, in: context) { $0.entry = target }
        finish()
    }

    private func finish() {
        if let onFinish { onFinish() } else { dismiss() }
    }
}

struct CategoryGrid: View {
    let categories: [LedgerCategory]
    @Binding var selection: LedgerCategory?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 5)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(categories) { category in
                let isSelected = selection == category
                let tint = Color(hex: category.colorHex)
                Button {
                    selection = isSelected ? nil : category
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: category.symbol)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.white : tint)
                            .frame(width: 46, height: 46)
                            .background(isSelected ? tint : tint.opacity(0.14), in: .circle)
                        Text(category.name)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(category.name))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
    }
}

extension Decimal {
    /// Exchange rates need more precision than money: up to six decimals.
    nonisolated var rateText: String {
        formatted(.number.grouping(.never).precision(.fractionLength(0...6)))
    }
}
