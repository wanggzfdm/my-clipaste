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
    "clipaste/Views/ClipboardMainView.swift",
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
expectSourceContains("var cardCornerRadius: CGFloat { style == .paste ? 16 : 16 }", "card radius preserves standard appearance")
expectSourceContains("var cardSelectedBorderWidth: CGFloat { style == .paste ? 2.5 : 6 }", "selection border differs by theme")
expectSourceContains("var cardSurfaceTint: Color {", "card surface uses a shared color token")
expectSourceContains("static let panelCornerRadius: CGFloat = 25", "outer glass tray uses the larger Paste-like corner radius")
expectSourceContains("var cardCornerRadius: CGFloat { style == .paste ? 16 : 16 }", "Liquid Glass cards use the tighter 16pt corner radius")
expectSourceContains(".clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))", "horizontal viewport clipping follows the outer tray corner radius")
expectSourceContains("let height: CGFloat = 315", "horizontal panel height matches the requested 315pt")

print("PasteThemeMappingTests: OK")
