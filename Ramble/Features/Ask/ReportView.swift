import SwiftData
import SwiftUI

/// 周报 / 月报: where the money went, what got done, what's next, and an optional AI comment.
struct ReportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var kind: PeriodReport.Kind
    @State private var period: QueryPeriod
    @State private var report: PeriodReport?
    @State private var comment: ReportComment?
    @State private var commentSource: CaptureSource?
    @State private var isCommenting = false
    @State private var commentError: String?
    @State private var consentProvider: AIProvider?

    init(kind: PeriodReport.Kind = .week) {
        _kind = State(initialValue: kind)
        _period = State(initialValue: ReportBuilder.defaultPeriod(kind))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("报告", selection: $kind) {
                        ForEach(PeriodReport.Kind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    periodBar
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
                }
                if let report {
                    overview(report)
                    if !report.highlights.isEmpty { highlights(report) }
                    aiSection(report)
                    if !report.categories.isEmpty { categories(report) }
                    if !report.biggest.isEmpty { biggest(report) }
                    tasksAndNotes(report)
                    if !report.upcomingBills.isEmpty || !report.upcomingExpiries.isEmpty { upcoming(report) }
                }
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "xmark", role: .close) { dismiss() }
                }
            }
            .onAppear(perform: rebuild)
            .onChange(of: kind) { _, newKind in
                period = ReportBuilder.defaultPeriod(newKind)
                rebuild()
            }
            .alert(consentProvider.map { String(localized: "发送给 \($0.displayName)？") } ?? "",
                   isPresented: Binding(get: { consentProvider != nil }, set: { if !$0 { consentProvider = nil } }),
                   presenting: consentProvider) { _ in
                Button("同意并继续") {
                    AISettings.hasCloudConsent = true
                    askForComment()
                }
                Button("取消", role: .cancel) {}
            } message: { provider in
                Text("只发送这份报告里的合计和分类金额，不发送每一笔的备注，用你自己的 API Key 直接发送到 \(provider.vendor)。")
            }
        }
    }

    private var periodBar: some View {
        HStack {
            Button("上一期", systemImage: "chevron.left") { move(-1) }
                .labelStyle(.iconOnly)
            Spacer()
            VStack(spacing: 2) {
                Text(period.label)
                    .font(.headline)
                if let subtitle = periodSubtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("下一期", systemImage: "chevron.right") { move(1) }
                .labelStyle(.iconOnly)
                .disabled(period.end > .now)
        }
        .buttonStyle(.borderless)
        .font(.title3)
    }

    private func overview(_ report: PeriodReport) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("支出")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(report.expense.money(report.currency))
                    .font(.largeTitle.weight(.bold).monospacedDigit())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if let change = QueryRunner.changeSentence(report.expense, against: report.previousExpense, label: report.previousLabel) {
                    Text(change)
                        .font(.subheadline)
                        .foregroundStyle(report.expense > report.previousExpense ? ModuleColor.warning : ModuleColor.money)
                }
            }
            .padding(.vertical, 4)
            HStack {
                figure("收入", report.income.money(report.currency))
                Divider()
                figure("结余", (report.income - report.expense).money(report.currency))
                Divider()
                figure("日均支出", report.dailyAverage.money(report.currency))
            }
            if let budget = report.budget, budget > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    let used = NSDecimalNumber(decimal: report.expense / budget).doubleValue
                    HStack {
                        Text("每月预算 \(budget.money(report.currency))")
                        Spacer()
                        Text(used.formatted(.percent.precision(.fractionLength(0))))
                            .foregroundStyle(used >= 1 ? ModuleColor.warning : .secondary)
                    }
                    .font(.subheadline)
                    ProgressView(value: min(1, used))
                        .tint(used >= 1 ? ModuleColor.warning : (used >= 0.8 ? ModuleColor.bills : ModuleColor.money))
                }
            }
        }
    }

    private func figure(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func highlights(_ report: PeriodReport) -> some View {
        Section("值得注意") {
            ForEach(report.highlights, id: \.self) { line in
                Label(line, systemImage: "lightbulb")
                    .font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private func aiSection(_ report: PeriodReport) -> some View {
        Section {
            if let comment {
                Text(comment.summary)
                    .font(.subheadline)
                ForEach(comment.suggestions, id: \.self) { suggestion in
                    Label(suggestion, systemImage: "arrow.turn.down.right")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let commentSource {
                    Label(commentSource.label, systemImage: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else if isCommenting {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("AI 正在看这份报告…")
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("让 AI 点评一下", systemImage: "sparkles") { askForComment() }
                    .disabled(!report.hasMoney && report.tasksCompleted == 0)
                if let commentError {
                    Text(commentError)
                        .font(.footnote)
                        .foregroundStyle(ModuleColor.warning)
                }
            }
        } header: {
            Text("AI 点评")
        } footer: {
            if comment == nil && !isCommenting {
                Text("只用这份报告里的合计和分类金额，不看每一笔的备注。")
            }
        }
    }

    private func categories(_ report: PeriodReport) -> some View {
        Section {
            ForEach(report.categories.prefix(8)) { line in
                let diff = line.amount - line.previous
                // Changes only mean something when the period before had spending too.
                ShareBar(label: line.name, amount: line.amount.money(report.currency), fraction: line.share,
                         color: Color(hex: line.colorHex),
                         note: report.previousExpense == 0 || diff == 0 ? nil
                             : line.previous == 0 ? String(localized: "新增")
                             : (diff > 0 ? "+" : "-") + abs(diff).money(report.currency))
            }
        } header: {
            Text("钱花在哪")
        } footer: {
            if report.previousExpense > 0 {
                Text("右侧小字是和\(report.previousLabel)相比的变化。")
            }
        }
    }

    private func biggest(_ report: PeriodReport) -> some View {
        Section("最大的几笔") {
            ForEach(report.biggest) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                        Text("\(entry.date.formatted(.dateTime.month().day())) · \(entry.category)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(entry.amount.money(report.currency))
                        .monospacedDigit()
                }
            }
        }
    }

    private func tasksAndNotes(_ report: PeriodReport) -> some View {
        Section("待办与笔记") {
            LabeledContent("完成的待办", value: "\(report.tasksCompleted) 件")
            LabeledContent("新加的待办", value: "\(report.tasksAdded) 件")
            if report.overdueOpen > 0 {
                LabeledContent("已过期还没做") {
                    Text("\(report.overdueOpen) 件")
                        .foregroundStyle(ModuleColor.warning)
                }
            }
            LabeledContent("记下的笔记", value: report.keyPoints > 0
                           ? String(localized: "\(report.noteEntries) 条，重点 \(report.keyPoints) 条")
                           : String(localized: "\(report.noteEntries) 条"))
            if !report.busiestNotes.isEmpty {
                LabeledContent("记得最多", value: report.busiestNotes.joined(separator: "、"))
            }
        }
    }

    private func upcoming(_ report: PeriodReport) -> some View {
        Section("接下来") {
            ForEach(report.upcomingBills) { bill in
                HStack {
                    Label(bill.name, systemImage: "calendar")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        if let amount = bill.amount { Text(amount.money(bill.currency)).monospacedDigit() }
                        Text(DayText.countdown(to: bill.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(report.upcomingExpiries) { item in
                HStack {
                    Label(item.name, systemImage: "hourglass")
                    Spacer()
                    Text(DayText.countdown(to: item.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "10月5日–11日 · 进行中"
    private var periodSubtitle: String? {
        var parts: [String] = []
        if kind == .week {
            let last = PeriodResolver.calendar.date(byAdding: .day, value: -1, to: period.end)!
            parts.append("\(period.start.formatted(.dateTime.month().day()))–\(last.formatted(.dateTime.month().day()))")
        }
        if report?.isCurrent == true { parts.append(String(localized: "进行中")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func move(_ steps: Int) {
        period = ReportBuilder.shifted(period, kind: kind, by: steps)
        rebuild()
    }

    private func rebuild() {
        let built = ReportBuilder.make(kind, period: period, context: context)
        report = built
        comment = ReportComment.cached(for: built)
        commentSource = nil
        commentError = nil
    }

    private func askForComment() {
        guard let report, !isCommenting else { return }
        isCommenting = true
        commentError = nil
        Task {
            do {
                let (result, source) = try await ReportCommentator.comment(on: report)
                comment = result
                commentSource = source
                ReportComment.store(result, for: report)
            } catch AIError.needsConsent(let provider) {
                consentProvider = provider
            } catch {
                commentError = error.localizedDescription
            }
            isCommenting = false
        }
    }
}
