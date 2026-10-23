import SwiftData
import SwiftUI

struct RemindersView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case bills, expiries
        var id: String { rawValue }
        var title: LocalizedStringResource {
            switch self {
            case .bills: "账单"
            case .expiries: "到期"
            }
        }
    }

    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Query(sort: \Bill.nextDueDate) private var bills: [Bill]
    @Query(sort: \ExpiryItem.expiryDate) private var expiries: [ExpiryItem]

    @State private var segment: Segment = .bills
    @State private var editingBill: Bill?
    @State private var editingExpiry: ExpiryItem?
    @State private var payingBill: Bill?
    @State private var isCreatingBill = false
    @State private var isCreatingExpiry = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("类别", selection: $segment) {
                        ForEach(Segment.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                switch segment {
                case .bills: billSections
                case .expiries: expirySections
                }
            }
            .overlay { emptyState }
            .navigationTitle("提醒")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(segment == .bills ? "新建账单" : "新建到期提醒", systemImage: "plus") {
                        if segment == .bills { isCreatingBill = true } else { isCreatingExpiry = true }
                    }
                }
            }
            .sheet(isPresented: $isCreatingBill) {
                NavigationStack { BillEditorView(bill: nil) }
            }
            .sheet(isPresented: $isCreatingExpiry) {
                NavigationStack { ExpiryEditorView(item: nil) }
            }
            .sheet(item: $editingBill) { bill in
                NavigationStack { BillEditorView(bill: bill) }
            }
            .sheet(item: $editingExpiry) { item in
                NavigationStack { ExpiryEditorView(item: item) }
            }
            .sheet(item: $payingBill) { bill in
                NavigationStack { MarkPaidView(bill: bill) }
                    .presentationDetents([.medium, .large])
            }
            .onChange(of: router.focus, initial: true) { openFocusedRecord() }
        }
    }

    private func openFocusedRecord() {
        switch router.focus {
        case .bill(let id, let pay):
            router.focus = nil
            guard let bill = bills.first(where: { $0.persistentModelID == id }) else { return }
            segment = .bills
            if pay && bill.isActive { payingBill = bill } else { editingBill = bill }
        case .expiry(let id):
            router.focus = nil
            guard let item = expiries.first(where: { $0.persistentModelID == id }) else { return }
            segment = .expiries
            editingExpiry = item
        default:
            break
        }
    }

    // MARK: - Bills

    @ViewBuilder
    private var billSections: some View {
        let active = bills.filter(\.isActive)
        let overdue = active.filter { DayText.daysUntil($0.nextDueDate) < 0 }
        let thisWeek = active.filter { (0...7).contains(DayText.daysUntil($0.nextDueDate)) }
        let later = active.filter { DayText.daysUntil($0.nextDueDate) > 7 }
        let finished = bills.filter { !$0.isActive }

        billSection("已逾期", overdue)
        billSection("7 天内", thisWeek)
        billSection("之后", later)
        billSection("已结束", finished)
    }

    @ViewBuilder
    private func billSection(_ title: LocalizedStringResource, _ list: [Bill]) -> some View {
        if !list.isEmpty {
            Section {
                ForEach(list) { bill in
                    BillRow(bill: bill)
                        .contentShape(.rect)
                        .onTapGesture { editingBill = bill }
                        .swipeActions(edge: .leading) {
                            if bill.isActive {
                                Button("已支付", systemImage: "checkmark") { payingBill = bill }
                                    .tint(ModuleColor.money)
                            }
                        }
                        .swipeActions {
                            Button("删除", systemImage: "trash", role: .destructive) {
                                context.delete(bill)
                            }
                        }
                        .contextMenu {
                            if bill.isActive {
                                Button("已支付", systemImage: "checkmark.circle") { payingBill = bill }
                            }
                            Button("编辑", systemImage: "pencil") { editingBill = bill }
                            Button("删除", systemImage: "trash", role: .destructive) { context.delete(bill) }
                        }
                }
            } header: {
                Text(title)
            }
        }
    }

    // MARK: - Expiry items

    @ViewBuilder
    private var expirySections: some View {
        let active = expiries.filter { !$0.isArchived }
        let soon = active.filter { DayText.daysUntil($0.expiryDate) <= 90 }
        let later = active.filter { DayText.daysUntil($0.expiryDate) > 90 }
        expirySection("90 天内", soon)
        expirySection("之后", later)
    }

    @ViewBuilder
    private func expirySection(_ title: LocalizedStringResource, _ list: [ExpiryItem]) -> some View {
        if !list.isEmpty {
            Section {
                ForEach(list) { item in
                    ExpiryRow(item: item)
                        .contentShape(.rect)
                        .onTapGesture { editingExpiry = item }
                        .swipeActions(edge: .leading) {
                            if item.renewalMonths > 0 {
                                Button("已续期", systemImage: "arrow.clockwise") {
                                    withAnimation { item.renew() }
                                }
                                .tint(ModuleColor.expiry)
                            }
                        }
                        .swipeActions {
                            Button("删除", systemImage: "trash", role: .destructive) {
                                context.delete(item)
                            }
                        }
                }
            } header: {
                Text(title)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch segment {
        case .bills where bills.isEmpty:
            ContentUnavailableView("还没有账单", systemImage: "creditcard",
                                   description: Text("信用卡、房租、订阅续费……加进来，到期前提醒你"))
        case .expiries where expiries.filter({ !$0.isArchived }).isEmpty:
            ContentUnavailableView("还没有到期提醒", systemImage: "person.text.rectangle",
                                   description: Text("证件、保险、合同、保修，提前几个月就提醒你"))
        default:
            EmptyView()
        }
    }
}

struct BillRow: View {
    let bill: Bill

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: bill.kind.symbol, color: bill.isActive ? ModuleColor.bills : ModuleColor.neutral)
            VStack(alignment: .leading, spacing: 2) {
                Text(bill.name)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(amountText)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                if bill.isActive {
                    CountdownBadge(date: bill.nextDueDate)
                }
            }
        }
    }

    private var amountText: String {
        let money = bill.amount.money(bill.currencyCode)
        return bill.isAmountEstimated ? String(localized: "约 \(money)") : money
    }

    private var subtitle: String {
        if !bill.isActive {
            if let paid = bill.lastPaidAt {
                return String(localized: "\(DayText.dayWithWeekday(paid)) 已支付")
            }
            return String(localized: "已结束")
        }
        let repeatText = bill.recurrence?.summary(anchor: bill.nextDueDate) ?? String(localized: "一次性")
        return "\(DayText.dayWithWeekday(bill.nextDueDate)) · \(repeatText)"
    }
}

struct ExpiryRow: View {
    let item: ExpiryItem

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: item.kind.symbol, color: ModuleColor.expiry)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                Text("\(item.expiryText) · \(ReminderRule.summary(of: item.reminderRules))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            countdown
        }
    }

    @ViewBuilder
    private var countdown: some View {
        let days = DayText.daysUntil(item.expiryDate)
        if days > 60 {
            Text("\(max(days / 30, 2)) 个月后")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        } else {
            CountdownBadge(date: item.expiryDate, urgentWithinDays: 30)
        }
    }
}
