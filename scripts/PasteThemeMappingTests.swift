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
    "clipaste/Views/ClipboardQuickLookView.swift",
    "clipaste/Views/ClipboardImageViews.swift",
    "clipaste/ViewModels/ClipboardViewModel+QuickLook.swift",
    "clipaste/Managers/ClipboardImagePipeline.swift",
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

expectSourceContains("func prewarmTextPreviews", "visible rich-text previews are prepared before the next presentation")
expectSourceContains("func prewarmThumbnail", "visible image cards can prewarm their thumbnail cache")
expectSourceContains("ListRenderEngine.shared.prewarmTextPreviews", "hiding the panel prewarms visible rich-text previews")
expectSourceContains("ClipboardImagePipeline.shared.prewarmThumbnail", "hiding the panel prewarms visible image thumbnails")
expectSourceContains("Color(nsColor: .textBackgroundColor)", "space text preview has an opaque readable background")
expectSourceContains("RoundedRectangle(cornerRadius: 12, style: .continuous)", "space text preview uses a bounded reading surface")
expectSourceContains("loadOriginalImageData", "quick-look image pipeline falls back to original image data")
expectSourceContains("applyQuickLookImageState(from: initialImage, preserveTargetSize: false)", "initial image decode recalculates the quick-look frame from its real aspect ratio")
expectSourceContains("await ClipboardImagePipeline.shared.thumbnail", "quick-look image loading falls back to the card thumbnail when original preview data is unavailable")
expectSourceContains("ClipboardQuickLookImageView(itemID: item.id", "Quick Look passes the selected image ID into its rendering fallback")
expectSourceContains("ClipboardThumbnailView(itemID: itemID", "Quick Look rendering directly falls back to the card thumbnail view")
expectSourceContains("NSScreen.main?.visibleFrame", "Quick Look image preview derives its bounds from the active screen")
expectSourceContains("visibleFrame.width * 0.52", "Quick Look image preview uses 52 percent of the visible screen width")
expectSourceContains("visibleFrame.height * 0.62", "Quick Look image preview uses 62 percent of the visible screen height")
expectSourceContains(".frame(width: previewFrameSize.width, height: previewFrameSize.height)", "Quick Look gives the popover an explicit screen-relative image frame")
