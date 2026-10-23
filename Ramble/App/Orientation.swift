import SwiftUI
import UIKit

/// Portrait on a phone-sized display; any way up where there's room, such as iPhone Duo's inner
/// display, which is wider than tall when opened like a book (a portrait-only app would sit sideways).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationPolicy.mask(for: window?.bounds.size)
    }
}

nonisolated enum OrientationPolicy {
    /// iPhone Duo's inner display is 626 points at its narrowest; the largest one-display iPhone, 440.
    static let roomyShortSide: CGFloat = 600

    static func mask(for size: CGSize?) -> UIInterfaceOrientationMask {
        guard let size, min(size.width, size.height) >= roomyShortSide else { return .portrait }
        return .allButUpsideDown
    }
}

extension View {
    /// Folding or unfolding changes the window's size: ask iOS to check the orientations again.
    func refreshesOrientationOnResize() -> some View {
        onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                for window in scene.windows {
                    window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                }
            }
        }
    }
}
