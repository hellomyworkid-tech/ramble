import Combine
import CoreSpotlight
import StoreKit
import SwiftData
import SwiftUI

enum AppTab: String, Hashable {
    case today, tasks, notes, ledger, reminders
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    @State private var router = AppRouter.shared
    @State private var isCapturing = false
    @State private var captureStart: CaptureStart?
    @State private var askRequest: AppRouter.AskRequest?
    @State private var reportKind: PeriodReport.Kind?
    /// The day the tabs were built for. Today's to-dos and this month's spending are filtered at
    /// build time, so a Today page left open past midnight (or the 1st) would keep yesterday's figures.
    @State private var day = Calendar.current.startOfDay(for: .now)

    var body: some View {
        TabView(selection: $router.tab) {
            Tab("今天", systemImage: "house", value: AppTab.today) {
                TodayView(selection: $router.tab)
            }
            Tab("待办", systemImage: "checkmark.circle", value: AppTab.tasks) {
                TasksView()
            }
            Tab("笔记", systemImage: "note.text", value: AppTab.notes) {
                NotesView()
            }
            Tab("账本", systemImage: "book.closed", value: AppTab.ledger) {
                LedgerView()
            }
            Tab("提醒", systemImage: "bell", value: AppTab.reminders) {
                RemindersView()
            }
        }
        .id(day)
        .tabViewStyle(.sidebarAdaptable)
        // The tab bar stays put: shrinking on scroll and growing back only on another scroll down
        // made it hard to predict, and the tabs are what people reach for.
        .tabBarMinimizeBehavior(.never)
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refreshDay() }
        .captureAccessory(isEnabled: !router.hidesCaptureBar) {
            CaptureBar { isCapturing = true }
        }
        .sheet(isPresented: $isCapturing, onDismiss: {
            if case .shared(let item) = captureStart { ShareInbox.shared?.remove(item) }
            captureStart = nil
            if ReviewPrompt.isDue {
                ReviewPrompt.isDue = false
                requestReview()
            }
            // Something else may have been shared meanwhile.
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                openNextShare()
            }
        }) {
            CaptureSheet(start: captureStart)
        }
        .sheet(item: $askRequest) { request in
            AskView(initialQuestion: request.question)
        }
        .sheet(item: $reportKind) { kind in
            ReportView(kind: kind)
        }
        .onChange(of: router.pendingAsk, initial: true) { _, request in
            guard let request else { return }
            router.pendingAsk = nil
            present { askRequest = request }
        }
        .onChange(of: router.pendingReport, initial: true) { _, kind in
            guard let kind else { return }
            router.pendingReport = nil
            present { reportKind = kind }
        }
        .onOpenURL { router.open($0) }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                SpotlightIndex.open(id, router: router, context: AppSchema.shared.mainContext)
            }
        }
        .onChange(of: router.pendingCapture, initial: true) { _, start in
            guard let start else { return }
            router.pendingCapture = nil
            captureStart = start
            if isCapturing {
                // A sheet that's already open keeps its own state; open a fresh one.
                isCapturing = false
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    captureStart = start
                    isCapturing = true
                }
            } else {
                isCapturing = true
            }
        }
        // The lock has its own window; this only keeps the very first frame covered.
        .overlay {
            if AppLock.shared.isLocked {
                Rectangle().fill(.background).ignoresSafeArea()
            }
        }
        .background(KeyboardDismissalInstaller())
        .environment(router)
        .onChange(of: router.focus) { _, focus in
            // A notification or search result should land on the record, not behind a sheet.
            if focus != nil {
                isCapturing = false
                askRequest = nil
                reportKind = nil
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            AppLock.shared.scenePhaseChanged(to: phase)
            switch phase {
            case .active:
                refreshDay()
                // Tasks ticked off on a widget while the app was closed.
                WidgetBridge.applyPendingCompletions(context: AppSchema.shared.mainContext)
                WidgetBridge.setNeedsRefresh()
                NotificationScheduler.shared.setNeedsReschedule()
                SpotlightIndex.shared.setNeedsRefresh()
                openNextShare()
                // Downloads that finished in the background get checked now the app is in front.
                OpenModelStore.shared.refresh()
                SpeechModelStore.shared.refresh()
                let base = UserDefaults.standard.string(forKey: AppSettings.baseCurrencyKey) ?? AppSettings.defaultBaseCurrency
                Task { await ExchangeRates.shared.refreshIfNeeded(base: base) }
                // The day's backup, a few seconds in so it doesn't slow the app opening.
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    AutoBackup.shared.runIfDue(context: AppSchema.shared.mainContext)
                }
            case .background:
                // A deletion still waiting for 撤销 happens now, before the app may be closed.
                PendingDeletion.shared.commit()
                NotificationScheduler.scheduleBackgroundRefresh()
                WidgetBridge.refresh(context: AppSchema.shared.mainContext)
                // An open model can hold a couple of GB; iOS ends apps that keep that much in the background.
                Task {
                    await LocalAI.releaseMemory()
                    await SpeechModelEngine.shared.unload()
                }
            default: break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            NotificationScheduler.shared.setNeedsReschedule()
            WidgetBridge.setNeedsRefresh()
            SpotlightIndex.shared.setNeedsRefresh()
        }
    }
}

extension RootView {
    /// Rebuilds the tabs when the date has moved on since they were built.
    fileprivate func refreshDay() {
        let today = Calendar.current.startOfDay(for: .now)
        if today != day { day = today }
    }

    /// What was shared from another app while this one was away, one at a time.
    fileprivate func openNextShare() {
        guard !isCapturing, askRequest == nil, reportKind == nil, let item = ShareInbox.shared?.pending().first else { return }
        router.startCapture(.shared(item))
    }

    /// Shows one sheet at a time: whatever is up closes first.
    fileprivate func present(_ show: @escaping () -> Void) {
        guard isCapturing || askRequest != nil || reportKind != nil else {
            show()
            return
        }
        isCapturing = false
        askRequest = nil
        reportKind = nil
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            show()
        }
    }
}

extension View {
    /// The capture bar above the tab bar; screens with their own composer switch it off (iOS 26.1+).
    @ViewBuilder
    func captureAccessory<Content: View>(isEnabled: Bool, @ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 26.1, *) {
            tabViewBottomAccessory(isEnabled: isEnabled, content: content)
        } else {
            tabViewBottomAccessory(content: content)
        }
    }
}

/// The always-available "just say it" entry that sits above the tab bar.
struct CaptureBar: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.tint)
                if placement == .inline {
                    Text("记一下")
                } else {
                    Text("说点什么，AI 帮你整理")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "keyboard")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("快速记录"))
    }
}
