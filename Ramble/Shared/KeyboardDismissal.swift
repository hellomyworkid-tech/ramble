import SwiftUI
import UIKit

/// Tapping the empty space of a list or form, between and around its rows, puts the keyboard
/// away. Taps on rows go through untouched: a row may hold a button, or the edge of the very
/// field being typed in. So do taps on a row's swipe actions, which sit outside its cell.
final class KeyboardDismissal: NSObject, UIGestureRecognizerDelegate {
    private static let shared = KeyboardDismissal()

    /// Watches taps anywhere in `window`, sheets included.
    static func install(in window: UIWindow) {
        guard !(window.gestureRecognizers ?? []).contains(where: { $0.delegate === shared }) else { return }
        let tap = UITapGestureRecognizer(target: shared, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        tap.delegate = shared
        window.addGestureRecognizer(tap)
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        tap.view?.endEditing(true)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        var cell: UICollectionViewCell?
        while let current = view {
            if current is UITextField || current is UITextView || current is UITableViewCell { return false }
            if String(describing: type(of: current)).contains("SwipeAction") { return false }
            if cell == nil, let found = current as? UICollectionViewCell { cell = found }
            // Lists and forms are collection views. Section headers and footers are cells too, but
            // only rows have an index path.
            if let list = current as? UICollectionView {
                return cell.map { list.indexPath(for: $0) == nil } ?? true
            }
            if current is UITableView { return true }
            view = current.superview
        }
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

/// Puts `KeyboardDismissal` on the window it ends up in.
struct KeyboardDismissalInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> WindowWatcher {
        let view = WindowWatcher()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: WindowWatcher, context: Context) {}

    final class WindowWatcher: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else { return }
            KeyboardDismissal.install(in: window)
            SwipeActionGuard.install(in: window)
        }
    }
}
