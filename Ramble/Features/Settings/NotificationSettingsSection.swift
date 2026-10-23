import SwiftData
import SwiftUI
import UserNotifications

struct NotificationSettingsSection: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: UNAuthorizationStatus = .notDetermined
    @State private var scheduledCount = 0

    var body: some View {
        Section {
            LabeledContent("通知", value: statusText)
            switch status {
            case .notDetermined:
                Button("开启通知") {
                    Task {
                        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                        await NotificationScheduler.shared.reschedule()
                        await refresh()
                    }
                }
            case .denied:
                Button("去系统设置开启") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
            default:
                LabeledContent("已安排的提醒", value: String(localized: "\(scheduledCount) 个提醒"))
            }
            Toggle("周一推送周报", isOn: reportToggle(ReportSettings.weeklyKey))
            Toggle("每月 1 日推送月报", isOn: reportToggle(ReportSettings.monthlyKey))
            #if DEBUG
            Button("5 秒后预演下一条提醒", action: sendTest)
            #endif
        } header: {
            Text("提醒")
        } footer: {
            Text("iOS 每个 App 最多同时排 64 条提醒。随口记会自动排最近的，每次打开时补上后面的。")
        }
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    /// Report reminders default to on; changing one reschedules.
    private func reportToggle(_ key: String) -> Binding<Bool> {
        Binding(get: { UserDefaults.standard.object(forKey: key) as? Bool ?? true },
                set: { value in
                    UserDefaults.standard.set(value, forKey: key)
                    Task {
                        await NotificationScheduler.shared.reschedule()
                        await refresh()
                    }
                })
    }

    private var statusText: String {
        switch status {
        case .authorized, .provisional, .ephemeral: String(localized: "已开启")
        case .denied: String(localized: "已关闭")
        default: String(localized: "未设置")
        }
    }

    private func refresh() async {
        let center = UNUserNotificationCenter.current()
        status = await center.notificationSettings().authorizationStatus
        scheduledCount = await center.pendingNotificationRequests().count
    }

    #if DEBUG
    /// Replays the next real reminder (same text and buttons) in 5 seconds.
    private func sendTest() {
        let scheduler = NotificationScheduler.shared
        guard let context = scheduler.container?.mainContext else { return }
        let next = scheduler.plan(in: context, now: .now).min { $0.fireDate < $1.fireDate }
        let reminder = PlannedReminder(target: next?.target ?? .openApp, targetID: next?.targetID ?? "",
                                       fireDate: .now.addingTimeInterval(5),
                                       title: next?.title ?? String(localized: "测试提醒"),
                                       body: next?.body ?? String(localized: "通知工作正常。"),
                                       category: next?.category ?? ReminderPlanner.Category.openApp,
                                       threadID: next?.threadID ?? "test")
        Task {
            try? await UNUserNotificationCenter.current().add(
                NotificationScheduler.request(for: reminder, identifier: NotificationScheduler.snoozePrefix + "test"))
            await refresh()
        }
    }
    #endif
}
