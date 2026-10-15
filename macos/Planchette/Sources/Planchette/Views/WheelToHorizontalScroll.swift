import AppKit
import SwiftUI

/// Lets the vertical wheel scroll a horizontal `ScrollView`. A row of tabs is wider
/// than the window as soon as a project has a few terminals, and a mouse wheel only
/// turns vertically: without this the bar answers to trackpad swipes alone.
///
/// Put it in the scroll view's content, as a background. It finds the `NSScrollView`
/// SwiftUI builds around that content and watches the wheel events of its window
/// (a local monitor: it sees an event before the scroll view does, and consumes only
/// the ones it turns sideways). A sideways swipe is left to the scroll view itself,
/// and so is every event while there is nothing to scroll.
struct WheelToHorizontalScroll: NSViewRepresentable {
    func makeNSView(context: Context) -> BridgeView { BridgeView() }
    func updateNSView(_ nsView: BridgeView, context: Context) {}

    final class BridgeView: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.turn(event) ?? event
            }
        }

        deinit { removeMonitor() }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// The event to hand on, or nil when it was used up here.
        private func turn(_ event: NSEvent) -> NSEvent? {
            guard let scrollView = enclosingScrollView, let window, event.window === window,
                  let document = scrollView.documentView
            else { return event }
            let point = scrollView.convert(event.locationInWindow, from: nil)
            guard scrollView.bounds.contains(point) else { return event }
            let clip = scrollView.contentView
            guard let x = WheelScroll.offset(
                current: clip.bounds.origin.x,
                overflow: document.frame.width - clip.bounds.width,
                deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                precise: event.hasPreciseScrollingDeltas)
            else { return event }
            clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
            scrollView.reflectScrolledClipView(clip)
            return nil
        }
    }
}

/// What one wheel event does to a horizontal scroll view. Pure, so it is tested.
enum WheelScroll {
    /// The new horizontal offset, or nil when this event is not ours to turn: a swipe
    /// that is mostly sideways is the scroll view's own business, and with nothing to
    /// scroll the event belongs to whoever is behind it.
    ///
    /// The sign follows the system: whichever way the user's scroll direction moves a
    /// vertical list down, it moves this one to the right.
    static func offset(current: CGFloat, overflow: CGFloat, deltaX: CGFloat, deltaY: CGFloat,
                       precise: Bool) -> CGFloat? {
        guard abs(deltaY) > abs(deltaX), overflow > 1 else { return nil }
        // A wheel reports lines, a trackpad points.
        let unit: CGFloat = precise ? 1 : 12
        return min(max(current - deltaY * unit, 0), overflow)
    }
}
