import UIKit

/// A finger on one of a row's swipe actions (重点, 删除…) holds the list still until it lifts.
///
/// The list would otherwise start scrolling as soon as a tap drifts about 10 points up or down,
/// easy to do right after swiping. Scrolling shuts the actions and cancels the tap, so they slid
/// away with nothing done. Only watches: it never recognizes, and so never takes a touch.
final class SwipeActionGuard: UIGestureRecognizer {
    private weak var heldList: UIScrollView?

    /// Watches touches anywhere in `window`, sheets included.
    static func install(in window: UIWindow) {
        guard !(window.gestureRecognizers ?? []).contains(where: { $0 is SwipeActionGuard }) else { return }
        let watcher = SwipeActionGuard(target: nil, action: nil)
        watcher.cancelsTouchesInView = false
        watcher.delaysTouchesBegan = false
        watcher.delaysTouchesEnded = false
        window.addGestureRecognizer(watcher)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard heldList == nil else { return }
        if let list = touches.first.flatMap(Self.listOfSwipeAction(under:)) {
            heldList = list
            list.panGestureRecognizer.isEnabled = false
        } else {
            state = .failed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }

    override func reset() {
        heldList?.panGestureRecognizer.isEnabled = true
        heldList = nil
    }

    /// The list whose row's swipe action `touch` is on, if it's on one. They sit beside the row's
    /// cell, in views of the system's own.
    private static func listOfSwipeAction(under touch: UITouch) -> UIScrollView? {
        var view = touch.view
        var isOnAction = false
        while let current = view {
            if String(describing: type(of: current)).contains("SwipeAction") { isOnAction = true }
            if let list = current as? UICollectionView { return isOnAction ? list : nil }
            view = current.superview
        }
        return nil
    }
}
