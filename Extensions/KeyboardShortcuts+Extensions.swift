import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleClipboardPanel = Self(
        "toggleClipboardPanel",
        default: .init(.c, modifiers: [.command, .shift])
    )

    static let translateSelectedText = Self(
        "translateSelectedText",
        default: .init(.space, modifiers: [.control, .shift])
    )
}
