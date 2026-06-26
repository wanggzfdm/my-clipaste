import AppKit
import SwiftUI

struct ClipboardQuickLookWindowPresenter: NSViewRepresentable {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("clipaste.quickLookPanel")

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
        private static let quickLookWindowIdentifier = ClipboardQuickLookWindowPresenter.windowIdentifier

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
            panel?.makeKeyAndOrderFront(nil)
        }

        private func makePanel(item: ClipboardItem, viewModel: ClipboardViewModel) {
            let hostingController = makeHostingController(item: item, viewModel: viewModel)
            let panel = ClipboardQuickLookFloatingPanel(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )

            panel.identifier = Self.quickLookWindowIdentifier
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
            panel.makeKeyAndOrderFront(nil)
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

            let frameSize = panel.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
            let origin = preferredBubbleOrigin(frameSize: frameSize, screen: screen)
            panel.setFrame(NSRect(origin: origin, size: frameSize), display: true)
        }

        private func preferredBubbleOrigin(frameSize: NSSize, screen: NSScreen) -> NSPoint {
            let visibleFrame = screen.visibleFrame
            let gap: CGFloat = 10

            if let itemAnchorFrame = currentItemAnchorFrame() {
                let proposedX = itemAnchorFrame.midX - frameSize.width / 2
                let aboveY = itemAnchorFrame.maxY + gap
                let belowY = itemAnchorFrame.minY - frameSize.height - gap
                let clampedX = min(
                    max(proposedX, visibleFrame.minX + 12),
                    visibleFrame.maxX - frameSize.width - 12
                )

                if aboveY + frameSize.height <= visibleFrame.maxY - 12 {
                    return NSPoint(x: clampedX, y: aboveY)
                }

                if belowY >= visibleFrame.minY + 12 {
                    return NSPoint(x: clampedX, y: belowY)
                }

                let clampedY = min(
                    max(aboveY, visibleFrame.minY + 12),
                    visibleFrame.maxY - frameSize.height - 12
                )
                return NSPoint(x: clampedX, y: clampedY)
            }

            if let anchorWindow = anchorView?.window {
                let anchorFrame = anchorWindow.frame
                let proposedX = anchorFrame.midX - frameSize.width / 2
                let proposedY = anchorFrame.maxY + gap
                let clampedX = min(max(proposedX, visibleFrame.minX + 12), visibleFrame.maxX - frameSize.width - 12)
                return NSPoint(x: clampedX, y: min(proposedY, visibleFrame.maxY - frameSize.height - 12))
            }

            return NSPoint(
                x: visibleFrame.midX - frameSize.width / 2,
                y: visibleFrame.midY - frameSize.height / 2
            )
        }

        private func currentItemAnchorFrame() -> CGRect? {
            guard let presentedItem else { return nil }
            return currentViewModel?.quickLookAnchorFrame(for: presentedItem.id)
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
            } else if item.fastParsedColor != nil {
                proposedSize = NSSize(width: 280, height: 120)
            } else {
                proposedSize = NSSize(width: 800, height: 610)
            }

            let maxSize = NSSize(
                width: min(820, screen.frame.width * 0.82),
                height: min(720, screen.frame.height * 0.82)
            )
            let widthScale = maxSize.width / max(proposedSize.width, 1)
            let heightScale = maxSize.height / max(proposedSize.height, 1)
            let scale = min(1, widthScale, heightScale)

            let tailSpace: CGFloat = 8
            return NSSize(
                width: max(280, proposedSize.width * scale),
                height: max(120, proposedSize.height * scale) + tailSpace
            )
        }

        private func targetScreen() -> NSScreen? {
            if let itemAnchorFrame = currentItemAnchorFrame() {
                let anchorCenter = NSPoint(x: itemAnchorFrame.midX, y: itemAnchorFrame.midY)
                if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchorCenter) }) {
                    return screen
                }
            }

            if let window = anchorView?.window {
                let windowCenter = NSPoint(x: window.frame.midX, y: window.frame.midY)
                if let screen = NSScreen.screens.first(where: { $0.frame.contains(windowCenter) }) {
                    return screen
                }
            }

            if let screen = NSScreen.screenContainingMouse {
                return screen
            }

            return NSScreen.main ?? NSScreen.screens.first
        }

        private func closePanel() {
            guard let panel else { return }
            let shouldRestorePanelFocus = panel.isKeyWindow
                && ClipboardPanelManager.shared.panel?.isVisible == true

            panel.delegate = nil
            panel.close()
            self.panel = nil
            presentedItem = nil
            presentedItemID = nil

            if shouldRestorePanelFocus {
                ClipboardPanelManager.shared.panel?.makeKeyAndOrderFront(nil)
            }
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
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct BubbleTailShape: Shape {
    var bodyCornerRadius: CGFloat = 16
    var tailWidth: CGFloat = 14
    var tailHeight: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let r = bodyCornerRadius
        let tw = tailWidth
        let th = tailHeight

        // The body occupies the top portion; the tail hangs below it
        let bodyBottom = rect.maxY - th
        let tailCenterX = rect.midX

        var path = Path()

        // Top-left corner
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.minY + r),
            radius: r,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        // Top edge
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        // Top-right corner
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
            radius: r,
            startAngle: .degrees(270),
            endAngle: .degrees(0),
            clockwise: false
        )
        // Right edge down to body bottom
        path.addLine(to: CGPoint(x: rect.maxX, y: bodyBottom - r))
        // Bottom-right corner
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: bodyBottom - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        // Bottom edge → right base of tail
        path.addLine(to: CGPoint(x: tailCenterX + tw / 2, y: bodyBottom))
        // Tail triangle: tip pointing down
        path.addLine(to: CGPoint(x: tailCenterX, y: bodyBottom + th))
        path.addLine(to: CGPoint(x: tailCenterX - tw / 2, y: bodyBottom))
        // Bottom edge ← left base of tail → bottom-left corner
        path.addLine(to: CGPoint(x: rect.minX + r, y: bodyBottom))
        // Bottom-left corner
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: bodyBottom - r),
            radius: r,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        // Left edge
        path.closeSubpath()

        return path
    }
}

private struct ClipboardCenteredQuickLookContent: View {
    let item: ClipboardItem
    @ObservedObject var viewModel: ClipboardViewModel

    var body: some View {
        ClipboardQuickLookView(item: item, viewModel: viewModel)
            .background {
                VisualEffectView(material: .popover, blendingMode: .behindWindow)
            }
            .clipShape(BubbleTailShape())
            .overlay {
                BubbleTailShape()
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


extension NSWindow {
    var isClipasteQuickLookPanel: Bool {
        identifier == ClipboardQuickLookWindowPresenter.windowIdentifier
    }
}
