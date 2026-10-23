import SwiftData
import SwiftUI

/// "问一问": questions about the person's own records, answered from the records on the phone.
struct AskView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router

    /// A question on the page: answered (and kept in the history), or one that failed this time.
    private struct Turn: Identifiable {
        var id = UUID()
        var date = Date.now
        let question: String
        var record: AskRecord?
        var error: String?
        /// From an earlier visit: its numbers are as they were then, so it offers 「重新问」.
        var isEarlier = false

        init(question: String) {
            self.question = question
        }

        init(earlier record: AskRecord) {
            id = record.id
            date = record.date
            question = record.question
            self.record = record
            isEarlier = true
        }
    }

    @State private var turns: [Turn] = []
    @State private var loadedHistory = false
    @State private var confirmClear = false
    @State private var text = ""
    @State private var isAsking = false
    @State private var recorder = SpeechRecorder()
    @State private var textBeforeRecording = ""
    @State private var consentProvider: AIProvider?
    @State private var pendingQuestion = ""
    @FocusState private var focused: Bool
    private let initialQuestion: String?
    @State private var askedInitial = false

    static var suggestions: [String] {
        [String(localized: "这个月吃饭花了多少"), String(localized: "上个月钱主要花在哪"), String(localized: "这周还有哪些待办"),
         String(localized: "今年打车花了多少"), String(localized: "最近有什么要到期的"), String(localized: "本月结余多少"),
         String(localized: "上周完成了几件事"), String(localized: "下个月有哪些账单")]
    }

    init(initialQuestion: String? = nil) {
        self.initialQuestion = initialQuestion
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if turns.isEmpty { intro }
                        ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                            if index == 0 || !Calendar.current.isDate(turn.date, inSameDayAs: turns[index - 1].date) {
                                Text(DayText.due(turn.date, hasTime: false))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                            }
                            TurnView(question: turn.question, record: turn.record, error: turn.error,
                                     isEarlier: turn.isEarlier, open: open, askAgain: { ask(turn.question) })
                                .id(turn.id)
                                .contextMenu { menu(for: turn) }
                        }
                        if isAsking {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("正在查…")
                                    .foregroundStyle(.secondary)
                            }
                            .id("progress")
                        }
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .background(Color(.systemGroupedBackground))
                .onChange(of: turns.count) { _, _ in
                    withAnimation { proxy.scrollTo(turns.last?.id, anchor: .top) }
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle("问一问")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "xmark", role: .close) { dismiss() }
                }
                if !turns.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("清空记录", systemImage: "trash") { confirmClear = true }
                            .disabled(isAsking)
                    }
                }
            }
            .confirmationDialog("清空所有问答记录？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空记录", role: .destructive) {
                    turns = []
                    AskHistory.clear()
                }
            } message: {
                Text("只删除问一问里的记录，不会动你的账目、待办和笔记。")
            }
            .onChange(of: recorder.transcript) { _, spoken in
                let base = textBeforeRecording
                text = base + (base.isEmpty || spoken.isEmpty ? "" : " ") + spoken
            }
            .onAppear {
                if !loadedHistory {
                    loadedHistory = true
                    turns = AskHistory.load().map(Turn.init(earlier:))
                }
                if let initialQuestion, !askedInitial {
                    askedInitial = true
                    ask(initialQuestion)
                }
            }
            .onDisappear { Task { await recorder.cancel() } }
            .alert(consentProvider.map { String(localized: "发送给 \($0.displayName)？") } ?? "",
                   isPresented: Binding(get: { consentProvider != nil }, set: { if !$0 { consentProvider = nil } }),
                   presenting: consentProvider) { _ in
                Button("同意并继续") {
                    AISettings.hasCloudConsent = true
                    ask(pendingQuestion)
                }
                Button("取消", role: .cancel) {}
            } message: { provider in
                Text("这个问题（问笔记内容时还有相关的几段笔记）会用你自己的 API Key 直接发送到 \(provider.vendor)。账目数字始终在手机上计算。")
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("问问你记过的东西")
                .font(.title3.weight(.semibold))
            Text("花了多少、钱花在哪、还有什么待办、什么快到期，或者笔记里写过的事。数字都在手机上算，常见问题不用联网。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 8) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button(suggestion) { ask(suggestion) }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            MicButton(isRecording: recorder.state == .recording, isBusy: recorder.state == .preparing || recorder.state == .finishing,
                      level: recorder.level, size: 40) { toggleMic() }
            HStack(alignment: .top, spacing: 4) {
                if recorder.state == .recording || recorder.state == .finishing {
                    LiveTranscript(text: text, placeholder: "正在听…", maxLines: 4)
                } else {
                    TextField("问点什么", text: $text, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($focused)
                        .submitLabel(.send)
                        .onSubmit { ask(text) }
                }
                if !text.isEmpty, recorder.state == .idle {
                    Button("清空", systemImage: "xmark.circle.fill") {
                        text = ""
                        textBeforeRecording = ""
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.tertiary)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("清空内容")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
            Button("发送", systemImage: "arrow.up.circle.fill") { ask(text) }
                .labelStyle(.iconOnly)
                .font(.title)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAsking)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: Actions

    private func toggleMic() {
        Task {
            if recorder.state == .recording {
                await recorder.stop()
                if !text.trimmingCharacters(in: .whitespaces).isEmpty { ask(text) }
                return
            }
            guard recorder.state == .idle else { return }
            textBeforeRecording = text
            focused = false
            await recorder.start()
        }
    }

    private func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAsking else { return }
        text = ""
        focused = false
        isAsking = true
        pendingQuestion = question
        Task {
            if recorder.state == .recording { await recorder.stop() }
            let started = ContinuousClock.now
            var turn = Turn(question: question)
            do {
                let answer = try await AskEngine.ask(question, context: context)
                var record = AskRecord(id: turn.id, date: turn.date, question: question, answer: answer,
                                       currency: LedgerSummary.baseCurrency)
                if case .ai = answer.source {
                    let elapsed = (ContinuousClock.now - started).components
                    record.seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                }
                turn.record = record
                AskHistory.append(record)
            } catch AIError.needsConsent(let provider) {
                isAsking = false
                consentProvider = provider
                return
            } catch {
                turn.error = error.localizedDescription
            }
            turns.append(turn)
            isAsking = false
        }
    }

    @ViewBuilder
    private func menu(for turn: Turn) -> some View {
        Button("重新问", systemImage: "arrow.clockwise") { ask(turn.question) }
            .disabled(isAsking)
        if let answer = turn.record?.answer {
            Button("拷贝回答", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = ([answer.headline] + answer.details).joined(separator: "\n")
            }
        }
        Button("删除", systemImage: "trash", role: .destructive) {
            turns.removeAll { $0.id == turn.id }
            AskHistory.save(turns.compactMap(\.record))
        }
    }

    private func open(_ link: AskAnswer.Item.Link) {
        switch link {
        case .task(let id): router.open(.task, id: id)
        case .bill(let id): router.open(.bill, id: id)
        case .expiry(let id): router.open(.expiry, id: id)
        case .note(let id):
            if let note = ModelRef.fetch(Note.self, id, in: context) { router.open(note) }
        }
        dismiss()
    }
}

private struct TurnView: View {
    let question: String
    let record: AskRecord?
    let error: String?
    let isEarlier: Bool
    let open: (AskAnswer.Item.Link) -> Void
    let askAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 40)
                Text(question)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.accentColor.opacity(0.14), in: .rect(cornerRadius: 18))
            }
            if let record {
                AnswerCard(answer: record.answer, elapsed: record.seconds.map { .milliseconds(Int($0 * 1000)) },
                           currency: record.currency, open: open)
                if isEarlier {
                    // An answer from before: its numbers are as of then.
                    HStack {
                        Text("回答于 \(record.date.formatted(date: .omitted, time: .shortened))")
                        Spacer()
                        Button("重新问", systemImage: "arrow.clockwise", action: askAgain)
                            .buttonStyle(.borderless)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(ModuleColor.warning)
            }
        }
    }
}

struct AnswerCard: View {
    let answer: AskAnswer
    var elapsed: Duration?
    /// The currency the amounts were worked out in, for a kept answer; otherwise today's base currency.
    var currency: String?
    let open: (AskAnswer.Item.Link) -> Void
    @AppStorage(AppSettings.baseCurrencyKey) private var baseCurrency = AppSettings.defaultBaseCurrency

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(answer.headline)
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if !answer.details.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(answer.details, id: \.self) { line in
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !answer.bars.isEmpty {
                VStack(spacing: 10) {
                    ForEach(answer.bars.prefix(6)) { bar in
                        ShareBar(label: bar.label, amount: bar.amount.money(currency ?? baseCurrency), fraction: bar.fraction,
                                 color: Color(hex: bar.colorHex), note: bar.change)
                    }
                }
            }
            if !answer.items.isEmpty {
                VStack(spacing: 0) {
                    ForEach(answer.items) { item in
                        Button {
                            if let link = item.link { open(link) }
                        } label: {
                            itemRow(item)
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(item.link != nil)
                        if item.id != answer.items.last?.id { Divider() }
                    }
                }
            }
            sourceLabel
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
    }

    private func itemRow(_ item: AskAnswer.Item) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !item.trailing.isEmpty {
                Text(item.trailing)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.primary)
            }
            if item.link != nil {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(.rect)
    }

    private var sourceLabel: some View {
        let text: String = switch answer.source {
        case .rules: String(localized: "本机计算，没有联网")
        case .ai(let source):
            answer.plan?.subject == .notes
                ? String(localized: "\(source.label) · 根据你的笔记")
                : String(localized: "\(source.label)理解问题 · 数字在本机计算")
        }
        let time = elapsed.map { " · " + $0.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))) } ?? ""
        return Label(text + time, systemImage: answer.source == .rules ? "iphone" : "sparkles")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

/// A labelled share-of-total bar: category, amount, and how it changed.
struct ShareBar: View {
    let label: String
    let amount: String
    let fraction: Double
    let color: Color
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.subheadline)
                Spacer()
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(amount)
                    .font(.subheadline.monospacedDigit())
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule().fill(color).frame(width: max(4, geometry.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Lays chips out in rows, wrapping as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
