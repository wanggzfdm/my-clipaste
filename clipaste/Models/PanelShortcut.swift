import AppKit
import Foundation
import KeyboardShortcuts

enum PanelShortcutAction: String, CaseIterable, Identifiable {
    case toggleVerticalClipboard
    case nextList
    case prevList
    case previewSelection
    case toggleFavoriteSelection
    case clearHistory

    var id: String { rawValue }

    var defaultShortcut: KeyboardShortcuts.Shortcut? {
        switch self {
        case .toggleVerticalClipboard:
            .init(.t, modifiers: [.command, .shift])
        case .nextList:
            .init(.rightArrow, modifiers: [.command])
        case .prevList:
            .init(.leftArrow, modifiers: [.command])
        case .previewSelection:
            .init(.space)
        case .toggleFavoriteSelection:
            .init(.e, modifiers: [.control])
        case .clearHistory:
            .init(.r, modifiers: [.command, .shift])
        }
    }

    var allowsSingleKey: Bool {
        self == .previewSelection
    }
}

extension Notification.Name {
    static let panelShortcutDidChange = Notification.Name("panelShortcutDidChange")
}

enum PanelShortcutStore {
    private static let storagePrefix = "PanelShortcut_"
    private static let legacyKeyboardShortcutsPrefix = "KeyboardShortcuts_"
    private static let migrationVersionKey = "PanelShortcut_migrationVersion"
    private static let currentMigrationVersion = 2

    static func shortcut(for action: PanelShortcutAction) -> KeyboardShortcuts.Shortcut? {
        let defaults = UserDefaults.standard
        let key = storageKey(for: action)

        if let encoded = defaults.string(forKey: key) {
            return decodeShortcut(from: encoded)
        }

        if defaults.object(forKey: key) != nil {
            return nil
        }

        return action.defaultShortcut
    }

    static func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?, for action: PanelShortcutAction) {
        let defaults = UserDefaults.standard
        let key = storageKey(for: action)

        if let shortcut, let encoded = encodeShortcut(shortcut) {
            defaults.set(encoded, forKey: key)
        } else {
            defaults.set(false, forKey: key)
        }

        NotificationCenter.default.post(
            name: .panelShortcutDidChange,
            object: nil,
            userInfo: ["action": action.rawValue]
        )
    }

    static func reset(_ actions: [PanelShortcutAction] = PanelShortcutAction.allCases) {
        let defaults = UserDefaults.standard

        for action in actions {
            defaults.removeObject(forKey: storageKey(for: action))
        }

        NotificationCenter.default.post(name: .panelShortcutDidChange, object: nil)
    }

    static func migrateLegacyKeyboardShortcutsIfNeeded() {
        let defaults = UserDefaults.standard
        let migrationVersion = defaults.integer(forKey: migrationVersionKey)

        if migrationVersion < currentMigrationVersion {
            repairPreviewShortcutDisabledByLegacyMigration(in: defaults)
            defaults.set(currentMigrationVersion, forKey: migrationVersionKey)
        }

        for action in PanelShortcutAction.allCases {
            let localKey = storageKey(for: action)
            let legacyKey = legacyStorageKey(for: action)

            if defaults.object(forKey: localKey) == nil {
                if let encoded = defaults.string(forKey: legacyKey),
                   decodeShortcut(from: encoded) != nil {
                    defaults.set(encoded, forKey: localKey)
                }
            }

            defaults.removeObject(forKey: legacyKey)
        }
    }

    static func matches(_ event: NSEvent, action: PanelShortcutAction) -> Bool {
        guard let expectedShortcut = shortcut(for: action),
              let eventShortcut = KeyboardShortcuts.Shortcut(event: event) else {
            return false
        }

        return expectedShortcut == eventShortcut
    }

    private static func storageKey(for action: PanelShortcutAction) -> String {
        "\(storagePrefix)\(action.rawValue)"
    }

    private static func legacyStorageKey(for action: PanelShortcutAction) -> String {
        "\(legacyKeyboardShortcutsPrefix)\(action.rawValue)"
    }

    private static func repairPreviewShortcutDisabledByLegacyMigration(in defaults: UserDefaults) {
        let previewKey = storageKey(for: .previewSelection)

        if let disabledMarker = defaults.object(forKey: previewKey) as? Bool,
           disabledMarker == false {
            defaults.removeObject(forKey: previewKey)
        }
    }

    private static func encodeShortcut(_ shortcut: KeyboardShortcuts.Shortcut) -> String? {
        guard let data = try? JSONEncoder().encode(shortcut) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private static func decodeShortcut(from encoded: String) -> KeyboardShortcuts.Shortcut? {
        guard let data = encoded.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(KeyboardShortcuts.Shortcut.self, from: data)
    }
}
