import AppKit
import Foundation

@MainActor
final class GlobalSelectionTranslationService {
    static let shared = GlobalSelectionTranslationService()
    static let isEnabledDefaultsKey = "enableGlobalSelectedTextTranslation"

    private var isRunning = false

    private init() {}

    func translateFrontmostSelection() {
        guard UserDefaults.standard.bool(forKey: Self.isEnabledDefaultsKey) else {
            NSSound.beep()
            return
        }

        if ClipboardPanelManager.shared.translateCurrentPanelSelectionIfPossible() {
            return
        }

        guard isRunning == false else { return }
        isRunning = true

        Task { @MainActor in
            defer { isRunning = false }

            let sourceApp = NSWorkspace.shared.frontmostApplication
            guard let selectedText = await readSelectedTextFromFrontmostApp() else {
                NSSound.beep()
                ClipboardPanelManager.shared.showGlobalSelectionTranslationUnavailableNotice()
                return
            }

            ClipboardPanelManager.shared.presentGlobalSelectionTranslation(
                text: selectedText,
                sourceApp: sourceApp
            )
        }
    }

    private func readSelectedTextFromFrontmostApp() async -> String? {
        if let selectedText = selectedTextFromAccessibility() {
            return selectedText
        }

        try? await Task.sleep(for: .milliseconds(120))
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let initialChangeCount = pasteboard.changeCount

        ClipboardMonitor.shared.isIgnoredNextChange = true
        pasteboard.clearContents()
        postCommandC()

        let copiedText = await waitForCopiedText(
            pasteboard: pasteboard,
            initialChangeCount: initialChangeCount
        )

        ClipboardMonitor.shared.isIgnoredNextChange = true
        snapshot.restore(to: pasteboard)

        return copiedText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }

    private func selectedTextFromAccessibility() -> String? {
        let systemWideElement = AXUIElementCreateSystemWide()

        var focusedValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard focusedResult == .success,
              let focusedElement = focusedValue else {
            return nil
        }

        var selectedTextValue: CFTypeRef?
        let selectedTextResult = AXUIElementCopyAttributeValue(
            focusedElement as! AXUIElement,
            kAXSelectedTextAttribute as CFString,
            &selectedTextValue
        )

        guard selectedTextResult == .success,
              let selectedText = selectedTextValue as? String else {
            return nil
        }

        return selectedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }

    private func waitForCopiedText(
        pasteboard: NSPasteboard,
        initialChangeCount: Int
    ) async -> String? {
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(50))
            guard pasteboard.changeCount != initialChangeCount else { continue }
            if let text = pasteboard.string(forType: .string), text.isEmpty == false {
                return text
            }
        }

        return nil
    }

    private func postCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(8)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}

private struct PasteboardSnapshot {
    private struct Item {
        let values: [(NSPasteboard.PasteboardType, Data)]
    }

    private let items: [Item]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { pasteboardItem in
            Item(
                values: pasteboardItem.types.compactMap { type in
                    pasteboardItem.data(forType: type).map { (type, $0) }
                }
            )
        }
        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { item in
            let pasteboardItem = NSPasteboardItem()
            for (type, data) in item.values {
                pasteboardItem.setData(data, forType: type)
            }
            return pasteboardItem
        }
        pasteboard.writeObjects(restoredItems)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
