import AppKit
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"
    /// Fork 2.1.5-inspired glass panel chrome (fixed dark).
    case paste = "paste"

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        case .paste:
            return "Paste Style"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark, .paste:
            return .dark
        }
    }

    var nsAppearanceName: NSAppearance.Name? {
        switch self {
        case .system:
            return nil
        case .light:
            return .aqua
        case .dark, .paste:
            return .darkAqua
        }
    }

    var nsAppearance: NSAppearance? {
        guard let nsAppearanceName else { return nil }
        return Self.appearanceCache[nsAppearanceName]
    }

    var panelVisualStyle: PanelVisualStyle {
        self == .paste ? .paste : .standard
    }

    private static let appearanceCache: [NSAppearance.Name: NSAppearance] = {
        var cache: [NSAppearance.Name: NSAppearance] = [:]

        if let aquaAppearance = NSAppearance(named: .aqua) {
            cache[.aqua] = aquaAppearance
        }

        if let darkAquaAppearance = NSAppearance(named: .darkAqua) {
            cache[.darkAqua] = darkAquaAppearance
        }

        return cache
    }()
}
