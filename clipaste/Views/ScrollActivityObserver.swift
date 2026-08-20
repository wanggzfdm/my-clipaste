import AppKit
import SwiftUI

/// Detects live scrolling on the nearest enclosing `NSScrollView` (macOS 12+ safe).
/// Used to disable hover animations / Preference tracking while the list is flinging.
struct ScrollActivityObserver: NSViewRepresentable {
    @Binding var isScrolling: Bool

    func makeNSView(context: Context) -> NSView {
        let view = ScrollActivityProbeView()
        view.onScrollingChange = { scrolling in
            if isScrolling != scrolling {
                isScrolling = scrolling
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ScrollActivityProbeView else { return }
        view.onScrollingChange = { scrolling in
            if isScrolling != scrolling {
                isScrolling = scrolling
            }
        }
    }
}

private final class ScrollActivityProbeView: NSView {
    var onScrollingChange: ((Bool) -> Void)?

    private var observations: [NSObjectProtocol] = []
    private var endScrollWorkItem: DispatchWorkItem?
    private weak var observedScrollView: NSScrollView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        guard window != nil else { return }
        // Defer until SwiftUI finishes embedding into NSScrollView hierarchy.
        DispatchQueue.main.async { [weak self] in
            self?.attachToEnclosingScrollView()
        }
    }

    override func removeFromSuperview() {
        detach()
        super.removeFromSuperview()
    }

    private func attachToEnclosingScrollView() {
        guard let scrollView = enclosingScrollView ?? findScrollViewInAncestors() else { return }
        guard observedScrollView !== scrollView else { return }
        detach()
        observedScrollView = scrollView

        let center = NotificationCenter.default
        observations = [
            center.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                self?.setScrolling(true)
            },
            center.addObserver(
                forName: NSScrollView.didLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                self?.setScrolling(true)
                self?.scheduleScrollEnd()
            },
            center.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleScrollEnd(delay: 0.05)
            },
        ]
    }

    private func findScrollViewInAncestors() -> NSScrollView? {
        var current: NSView? = superview
        while let view = current {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }
            current = view.superview
        }
        return nil
    }

    private func setScrolling(_ scrolling: Bool) {
        endScrollWorkItem?.cancel()
        onScrollingChange?(scrolling)
    }

    private func scheduleScrollEnd(delay: TimeInterval = 0.12) {
        endScrollWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onScrollingChange?(false)
        }
        endScrollWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func detach() {
        endScrollWorkItem?.cancel()
        endScrollWorkItem = nil
        let center = NotificationCenter.default
        observations.forEach { center.removeObserver($0) }
        observations.removeAll()
        observedScrollView = nil
        onScrollingChange?(false)
    }
}
