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
    "clipaste/Views/ListRenderEngine.swift",
    "clipaste/ViewModels/ClipboardViewModel+Presentation.swift",
    "clipaste/ViewModels/ClipboardViewModel+Filtering.swift",
    "clipaste/ViewModels/ClipboardViewModel+Groups.swift",
    "clipaste/ViewModels/ClipboardViewModel+HistoryLoading.swift",
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

expectSourceContains("func applyImmediateScopeFilter", "group switches synchronously publish loaded first-page IDs")
expectSourceContains("withTransaction(transaction)", "group switches disable list replacement animations")
expectSourceContains("ListRenderEngine.shared.prewarmTextPreviews", "group switches prewarm target rich-text previews")
expectSourceContains("Task.sleep(nanoseconds: 0)", "vertical rich-text previews do not wait before rendering")
expectSourceContains(".id(viewModel.listContentEpoch)", "horizontal list keeps its stable content identity during group switches")
expectSourceContains(".animation(nil, value: viewModel.selectedGroupId)", "group selection changes do not animate list replacements")
