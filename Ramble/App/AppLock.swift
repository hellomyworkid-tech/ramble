import LocalAuthentication
import Observation
import SwiftUI
import UIKit

/// Face ID (or the passcode) when the app opens or comes back after a while, and a cover over
/// the app switcher's snapshot while it's away.
@Observable
final class AppLock {
    static let shared = AppLock()

    static let enabledKey = "security.appLock"
    static let graceKey = "security.appLockGrace"

    /// How long the app may be away before it asks again.
    enum Grace: Int, CaseIterable, Identifiable {
        case immediately = 0
        case oneMinute = 60
        case fiveMinutes = 300
        case fifteenMinutes = 900

        var id: Int { rawValue }

        var title: LocalizedStringResource {
            switch self {
            case .immediately: "立即"
            case .oneMinute: "1 分钟后"
            case .fiveMinutes: "5 分钟后"
            case .fifteenMinutes: "15 分钟后"
            }
        }
    }

    private(set) var isLocked: Bool { didSet { updateWindow() } }
    /// The app is in the background or the switcher: hide what's on screen.
    private(set) var isCovered = false { didSet { updateWindow() } }
    private(set) var isAuthenticating = false
    private(set) var lastError: String?
    private var leftAt: Date?
    /// Asked once on launch; after a cancel, the button asks again.
    private var promptedAtLaunch = false
    /// Above everything, sheets included, so nothing shows through.
    private var window: UIWindow?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var grace: Grace {
        Grace(rawValue: UserDefaults.standard.integer(forKey: graceKey)) ?? .immediately
    }

    private init() {
        isLocked = Self.isEnabled
    }

    /// What this phone unlocks with, for the settings row.
    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return String(localized: "面容 ID")
        case .touchID: return String(localized: "触控 ID")
        case .opticID: return String(localized: "视控 ID")
        default: return String(localized: "设备密码")
        }
    }

    /// Whether the phone has a passcode at all; without one there's nothing to check against.
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        guard Self.isEnabled else {
            // Only write when something changes: every write redraws the views that read these.
            if isLocked { isLocked = false }
            if isCovered { isCovered = false }
            if window != nil { window?.isHidden = true; window = nil }
            return
        }
        switch phase {
        case .background:
            isCovered = true
            if leftAt == nil { leftAt = .now }
        case .inactive:
            // The switcher, Control Center, or our own Face ID prompt: cover, but don't lock.
            if !isAuthenticating { isCovered = true }
        case .active:
            var prompt = false
            if let leftAt {
                if Date.now.timeIntervalSince(leftAt) >= Double(Self.grace.rawValue) { isLocked = true }
                prompt = isLocked
            } else if isLocked && !promptedAtLaunch {
                prompt = true
            }
            leftAt = nil
            promptedAtLaunch = true
            isCovered = false
            if prompt { Task { await unlock() } }
        @unknown default:
            break
        }
        updateWindow()
    }

    /// Asks for Face ID, falling back to the passcode.
    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let context = LAContext()
        context.localizedFallbackTitle = String(localized: "输入密码")
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "解锁随口记"))
            isLocked = false
            lastError = nil
        } catch let error as LAError where error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel {
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The cover is built once and then only shown or hidden: building a window and its views
    /// as the swipe-up begins made the leaving animation stutter.
    private func updateWindow() {
        let show = isLocked || isCovered
        if window == nil {
            guard show, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.rootViewController = UIHostingController(rootView: AppLockView(lock: self))
            self.window = window
        }
        window?.isHidden = !show
    }

    /// Turning the lock on asks once, so nobody locks themselves out with a phone that can't check.
    func setEnabled(_ enabled: Bool) async -> Bool {
        if enabled {
            let context = LAContext()
            do {
                try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "开启应用锁"))
            } catch {
                lastError = error.localizedDescription
                return false
            }
        }
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        isLocked = false
        lastError = nil
        return true
    }
}

/// Shown over the app while it's locked, or covered for the app switcher.
struct AppLockView: View {
    let lock: AppLock

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("随口记已锁定")
                    .font(.title3.weight(.semibold))
                if lock.isLocked && !lock.isCovered {
                    Button {
                        Task { await lock.unlock() }
                    } label: {
                        Text("用\(AppLock.biometryName)解锁")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(lock.isAuthenticating)
                    if let error = lock.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                }
            }
        }
        .accessibilityAddTraits(.isModal)
    }
}

/// The app-lock switch and how soon it asks again, for Settings.
struct AppLockSettingsSection: View {
    @AppStorage(AppLock.enabledKey) private var enabled = false
    @AppStorage(AppLock.graceKey) private var grace = AppLock.Grace.immediately.rawValue
    @State private var error: String?

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { enabled }, set: { newValue in
                Task {
                    if await AppLock.shared.setEnabled(newValue) {
                        error = nil
                    } else {
                        error = AppLock.shared.lastError
                    }
                }
            })) {
                Label("\(AppLock.biometryName)锁", systemImage: "faceid")
            }
            .disabled(!enabled && !AppLock.isAvailable)
            if enabled {
                Picker("离开后多久需要解锁", selection: $grace) {
                    ForEach(AppLock.Grace.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
        } header: {
            Text("隐私")
        } footer: {
            if let error {
                Text(error)
            } else if !AppLock.isAvailable && !enabled {
                Text("这台设备没有设置密码，无法开启。")
            } else {
                Text("打开随口记时需要验证；切到后台时，多任务界面里看不到内容。")
            }
        }
    }
}
