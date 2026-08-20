import Foundation

// Host-side mapping checks (no XCTest target). Run: swift scripts/PasteThemeMappingTests.swift

enum PanelVisualStyle: String {
    case standard
    case paste
}

enum AppTheme: String, CaseIterable {
    case system, light, dark, paste

    var panelVisualStyle: PanelVisualStyle {
        self == .paste ? .paste : .standard
    }

    var isForcedDark: Bool {
        self == .dark || self == .paste
    }
}

func expect(_ cond: Bool, _ msg: String) {
    if !cond {
        fputs("FAIL: \(msg)\n", stderr)
        exit(1)
    }
}

expect(AppTheme.paste.panelVisualStyle == .paste, "paste style")
expect(AppTheme.system.panelVisualStyle == .standard, "system standard")
expect(AppTheme.light.panelVisualStyle == .standard, "light standard")
expect(AppTheme.dark.panelVisualStyle == .standard, "dark remains standard chrome")
expect(AppTheme.paste.isForcedDark, "paste forced dark")
expect(AppTheme.allCases.map(\.rawValue).contains("paste"), "allCases includes paste")

print("PasteThemeMappingTests: OK")
