import AppKit
import SwiftUI

struct ClipboardQuickLookAnchorReporter: NSViewRepresentable {
    let itemID: UUID
    @ObservedObject var viewModel: ClipboardViewModel

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.itemID = itemID
        view.viewModel = viewModel
        return view
    }

    func updateNSView(_ nsView: ReportingView, context: Context) {
        nsView.itemID = itemID
        nsView.viewModel = viewModel
        nsView.reportSoon()
    }

    final class ReportingView: NSView {
        var itemID: UUID?
        weak var viewModel: ClipboardViewModel?
        private var notificationObservers: [NSObjectProtocol] = []

        deinit {
            for observer in notificationObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            if let itemID {
                Task { @MainActor [weak viewModel] in
                    viewModel?.removeQuickLookAnchorFrame(itemID: itemID)
                }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installWindowObservers()
            reportSoon()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            reportSoon()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            reportSoon()
        }

        override func layout() {
            super.layout()
            reportNow()
        }

        func reportSoon() {
            DispatchQueue.main.async { [weak self] in
                self?.reportNow()
            }
        }

        private func installWindowObservers() {
            for observer in notificationObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            notificationObservers = []

            guard let window else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                let observer = center.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.reportNow()
                }
                notificationObservers.append(observer)
            }
        }

        private func reportNow() {
            guard let itemID, let viewModel, let window else { return }
            let windowFrame = convert(bounds, to: nil)
            let screenFrame = window.convertToScreen(windowFrame)
            viewModel.updateQuickLookAnchorFrame(itemID: itemID, frame: screenFrame)
        }
    }
}
