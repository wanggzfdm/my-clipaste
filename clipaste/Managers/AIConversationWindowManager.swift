import AppKit
import SwiftUI

class AIConversationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AIConversationWindowManager: NSObject, NSWindowDelegate {
    static let shared = AIConversationWindowManager()

    private var openWindows: [String: NSWindow] = [:]

    private override init() {}

    func openConversation(
        title: String,
        configuration: AIConfiguration,
        messages: [AIChatMessage]
    ) {
        let windowTitle = title.isEmpty ? String(localized: "AI Conversation") : title
        let windowID = UUID().uuidString
        let conversationView = AIConversationView(
            windowID: windowID,
            title: title,
            configuration: configuration,
            initialMessages: messages
        )
        let hostingController = NSHostingController(rootView: conversationView)

        presentWindow(
            id: windowID,
            title: windowTitle,
            size: NSSize(width: 720, height: 640),
            hostingController: hostingController
        )
    }

    func openTranslation(
        title: String,
        configuration: AIConfiguration,
        sourceText: String
    ) {
        let windowTitle = title.isEmpty ? String(localized: "Translation") : title
        let windowID = UUID().uuidString
        let translationView = AITranslationWindowView(
            windowID: windowID,
            title: windowTitle,
            sourceText: sourceText,
            configuration: configuration
        )
        let hostingController = NSHostingController(rootView: translationView)

        presentWindow(
            id: windowID,
            title: windowTitle,
            size: NSSize(width: 900, height: 620),
            hostingController: hostingController,
            usesTransparentGlass: true
        )
    }

    private func presentWindow<Content: View>(
        id windowID: String,
        title: String,
        size: NSSize,
        hostingController: NSHostingController<Content>,
        usesTransparentGlass: Bool = false
    ) {
        let styleMask: NSWindow.StyleMask = usesTransparentGlass
            ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            : [.titled, .closable, .miniaturizable, .resizable]
        let window = AIConversationWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        window.title = title
        if usesTransparentGlass {
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            hostingController.view.wantsLayer = true
            hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
        window.center()
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.delegate = self

        openWindows[windowID] = window
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        NSApp.activate(ignoringOtherApps: true)

        TypeToSearchService.shared.isPaused = true
    }

    func close(windowID: String) {
        guard let window = openWindows[windowID] else { return }
        window.delegate = nil
        window.close()
        openWindows.removeValue(forKey: windowID)

        if openWindows.isEmpty {
            TypeToSearchService.shared.isPaused = false
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let windowID = openWindows.first(where: { $0.value === window })?.key else {
            return
        }

        openWindows.removeValue(forKey: windowID)
        if openWindows.isEmpty {
            TypeToSearchService.shared.isPaused = false
        }
    }
}
