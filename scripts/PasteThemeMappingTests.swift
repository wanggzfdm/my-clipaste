import Foundation

// Source-level mapping checks. Run: swift scripts/PasteThemeMappingTests.swift
let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let sourcePaths = [
    "clipaste/Models/AppTheme.swift",
    "clipaste/Models/PanelVisualStyle.swift",
    "clipaste/Views/ClipboardPasteCardView.swift",
    "clipaste/Views/ClipboardPasteHorizontalView.swift",
    "clipaste/Views/GlassEffects.swift",
    "clipaste/Views/LiquidGlassSurface.swift",
    "clipaste/Views/ClipboardPasteVerticalItemView.swift",
    "clipaste/Views/ClipboardEmptyStateView.swift",
    "clipaste/Managers/ClipboardPanelManager.swift"
]
let source = try sourcePaths
    .map { try String(contentsOf: projectRoot.appendingPathComponent($0), encoding: .utf8) }
    .joined(separator: "\n")

func expect(_ condition: Bool, _ message: String) {
    if !condition {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func expectSourceContains(_ snippet: String, _ message: String) {
    expect(source.contains(snippet), message)
}

expectSourceContains("style == .paste ? .hudWindow : .popover", "theme maps Paste to hudWindow and standard to popover")
expectSourceContains("case .standard: (layout == .vertical || layout == .compact) ? 14 : 0", "standard panel radius remains unchanged")
expectSourceContains("case .paste: Self.panelCornerRadius", "Paste panel radius is theme-specific")
expectSourceContains("var cardCornerRadius: CGFloat { style == .paste ? 25 : 16 }", "card radius preserves standard appearance")
expectSourceContains("var cardSelectedBorderWidth: CGFloat { style == .paste ? 2.5 : 6 }", "selection border differs by theme")
expectSourceContains("var cardSurfaceTint: Color {", "card surface uses a shared color token")
expectSourceContains("case system = \"system\"", "system appearance remains selectable")
expectSourceContains("case light = \"light\"", "light Liquid Glass appearance remains selectable")
expectSourceContains("case dark = \"dark\"", "dark Liquid Glass appearance remains selectable")
expectSourceContains("static let allCases: [AppTheme] = [.system, .light, .dark]", "settings expose exactly system, light, and dark appearances")
expectSourceContains("case .system, .light, .dark: .paste", "all active appearances use the Liquid Glass panel family")
expectSourceContains("case .light: return .aqua", "light appearance forces Aqua")
expectSourceContains("case .dark: return .darkAqua", "dark appearance forces Dark Aqua")
expectSourceContains("case .system: return nil", "system appearance follows macOS appearance")
expectSourceContains("Color(.sRGB, white: 0.96, opacity: 0.94)", "light Liquid Glass cards use opaque light surfaces")
expectSourceContains("Color(.sRGB, white: 0.10, opacity: 0.94)", "dark Liquid Glass cards use opaque dark surfaces")

print("PasteThemeMappingTests: OK")
