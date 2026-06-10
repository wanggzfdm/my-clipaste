import AppKit
import SwiftUI

struct ClipboardQuickLookWindowPresenter: NSViewRepresentable {
    @ObservedObject var viewModel: ClipboardViewModel

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.anchorView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.anchorView = nsView
        context.coordinator.update(item: viewModel.quickLookItem, viewModel: viewModel)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        weak var anchorView: NSView?
        private weak var currentViewModel: ClipboardViewModel?
        private var panel: ClipboardQuickLookFloatingPanel?
        private var presentedItemID: UUID?
        private var presentedItem: ClipboardItem?

        func update(item: ClipboardItem?, viewModel: ClipboardViewModel) {
            currentViewModel = viewModel

            guard let item else {
                closePanel()
                return
            }

            if panel == nil {
                makePanel(item: item, viewModel: viewModel)
                return
            }

            if presentedItemID != item.id {
                replaceContent(item: item, viewModel: viewModel)
            }

            layoutPanel()
            DispatchQueue.main.async { [weak self] in
                self?.layoutPanel()
            }
            panel?.orderFront(nil)
        }

        private func makePanel(item: ClipboardItem, viewModel: ClipboardViewModel) {
            let hostingController = makeHostingController(item: item, viewModel: viewModel)
            let panel = ClipboardQuickLookFloatingPanel(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )

            panel.contentViewController = hostingController
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 2)
            panel.delegate = self

            self.panel = panel
            presentedItem = item
            presentedItemID = item.id
            layoutPanel()
            panel.orderFront(nil)
            scheduleDeferredLayouts()
        }

        private func replaceContent(item: ClipboardItem, viewModel: ClipboardViewModel) {
            panel?.contentViewController = makeHostingController(item: item, viewModel: viewModel)
            presentedItem = item
            presentedItemID = item.id
            layoutPanel()
            scheduleDeferredLayouts()
        }

        private func makeHostingController(
            item: ClipboardItem,
            viewModel: ClipboardViewModel
        ) -> NSHostingController<ClipboardCenteredQuickLookContent> {
            let hostingController = NSHostingController(
                rootView: ClipboardCenteredQuickLookContent(item: item, viewModel: viewModel)
            )
            hostingController.sizingOptions = []
            return hostingController
        }

        private func layoutPanel() {
            guard let panel else { return }
            guard let screen = targetScreen() else { return }
            let contentSize = measuredContentSize(for: screen)

            let screenFrame = screen.frame
            let frameSize = panel.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
            let origin = NSPoint(
                x: screenFrame.midX - frameSize.width / 2,
                y: screenFrame.midY - frameSize.height / 2
            )
            panel.setFrame(NSRect(origin: origin, size: frameSize), display: true)
        }

        private func scheduleDeferredLayouts() {
            DispatchQueue.main.async { [weak self] in
                self?.layoutPanel()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.layoutPanel()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.layoutPanel()
            }
        }

        private func measuredContentSize(for screen: NSScreen) -> NSSize {
            guard let item = presentedItem else {
                return NSSize(width: 560, height: 420)
            }

            let proposedSize: NSSize
            if item.contentType == .image,
               let targetSize = currentViewModel?.previewTargetSize,
               targetSize.width > 0,
               targetSize.height > 0 {
                proposedSize = NSSize(width: targetSize.width + 32, height: targetSize.height + 32)
            } else if item.isFastLink {
                proposedSize = NSSize(width: 452, height: 220)
            } else if item.fastParsedColor != nil {
                proposedSize = NSSize(width: 280, height: 120)
            } else {
                proposedSize = NSSize(width: 732, height: 632)
            }

            let maxSize = NSSize(
                width: min(820, screen.frame.width * 0.82),
                height: min(720, screen.frame.height * 0.82)
            )
            let widthScale = maxSize.width / max(proposedSize.width, 1)
            let heightScale = maxSize.height / max(proposedSize.height, 1)
            let scale = min(1, widthScale, heightScale)

            return NSSize(
                width: max(280, proposedSize.width * scale),
                height: max(120, proposedSize.height * scale)
            )
        }

        private func targetScreen() -> NSScreen? {
            if let screen = NSScreen.screenContainingMouse {
                return screen
            }

            if let window = anchorView?.window {
                let windowCenter = NSPoint(x: window.frame.midX, y: window.frame.midY)
                if let screen = NSScreen.screens.first(where: { $0.frame.contains(windowCenter) }) {
                    return screen
                }
            }

            return NSScreen.main ?? NSScreen.screens.first
        }

        private func closePanel() {
            guard let panel else { return }
            panel.delegate = nil
            panel.close()
            self.panel = nil
            presentedItem = nil
            presentedItemID = nil
        }

        func windowWillClose(_ notification: Notification) {
            guard notification.object as? NSWindow === panel else { return }
            panel = nil
            presentedItem = nil
            presentedItemID = nil

            if currentViewModel?.quickLookItem != nil {
                currentViewModel?.dismissQuickLook()
            }
        }
    }
}

private final class ClipboardQuickLookFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct ClipboardCenteredQuickLookContent: View {
    let item: ClipboardItem
    @ObservedObject var viewModel: ClipboardViewModel

    var body: some View {
        ClipboardQuickLookView(item: item, viewModel: viewModel)
            .background {
                VisualEffectView(material: .popover, blendingMode: .behindWindow)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
    }
}

private extension NSScreen {
    static var screenContainingMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
    }
}
