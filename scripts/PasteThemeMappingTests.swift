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
    "clipaste/Managers/ClipboardPanelManager.swift",
    "clipaste/Managers/ClipboardRuntimeStore.swift",
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
expectSourceContains("isScopeRefreshSuppressed", "group switches can suppress intermediate scope refreshes")
expectSourceContains("let presentationWarmItems = Array(items.prefix(ClipboardHistoryWarmCache.defaultLimit))", "panel hide warms the retained first-page history rather than only the current group")
expectSourceContains("func refreshDataWhilePanelHidden", "clipboard changes refresh the retained data snapshot while the panel is hidden")
expectSourceContains("refreshDataWhilePanelHidden()", "hidden clipboard changes start a background snapshot refresh instead of waiting for the next presentation")
expectSourceContains("backgroundHistoryRefreshTask", "hidden snapshot refresh work is tracked independently from visible presentation loading")
expectSourceContains("ListRenderEngine.shared.prewarmTextPreviews(for: presentationWarmItems)", "panel hide prewarms rich text for the next group switch")
expectSourceContains("for item in presentationWarmItems where item.contentType == .image", "panel hide prewarms image cards beyond the current group")
expectSourceContains("func cachedThumbnail(for itemID: UUID, maxPixelSize: Int)", "thumbnail pipeline exposes synchronously readable warmed images")
expectSourceContains("image ?? ClipboardImagePipeline.shared.cachedThumbnail", "new card views render a warmed thumbnail on their first frame")
expectSourceContains("func prepareDisplayedScopeResources", "group target resources are warmed after the new scope is committed")
expectSourceContains("func resolveScopeSnapshotBeforeCommit", "incomplete in-memory group scopes resolve their database snapshot before replacing visible cards")
expectSourceContains("fetchItemsByScope", "group scope snapshot resolution queries the database before its visible commit")
expectSourceContains("applyDisplayedItemIDsIfChanged(resolvedIDs)", "a database-backed group scope commits one complete ID snapshot")
expect(!source.contains(".id(viewModel.listContentEpoch)"), "horizontal group switches preserve card identity instead of recreating the whole card stack")
expectSourceContains(".glassEffect(.regular, in: .rect(cornerRadius: 16))", "outer Liquid Glass keeps the full frosted regular material")
expectSourceContains("Color.white.opacity(0.06)", "outer Liquid Glass uses a soft bright tint instead of a dark overlay")
expect(!source.contains(".glassEffect(.clear, in: .rect(cornerRadius: 16))"), "outer Liquid Glass avoids the overly clear non-frosted variant")
expectSourceContains(".overlay(Color.white.opacity(0.03))", "outer Liquid Glass fallback keeps its highlight subtle")
expectSourceContains("func handleQuickLookTextSelectionChange", "Quick Look text selection is handled by the view model")
expectSourceContains("Task.sleep(for: .milliseconds(120))", "Quick Look selection copying is debounced while dragging")
expectSourceContains("pasteboard.setString(selection, forType: .string)", "Quick Look text selection is written to the system pasteboard")
expectSourceContains("self.quickLookSelectedText == selection", "stale Quick Look selection copy tasks cannot overwrite the latest selection")
expectSourceContains("lastAutoCopiedQuickLookText = selection", "Quick Look tracks the latest automatically copied selection")
expectSourceContains("ClipboardMonitor.shared.isIgnoredNextChange = true", "Quick Look automatic selection copy is ignored by the clipboard capture monitor")
expectSourceContains("ClipboardRuntimeBootstrapPolicy.resolve", "runtime store resolves persistent startup failures through the recovery policy")
expect(!source.contains("currentRuntime = try! ClipboardModelContainerFactory.shared.makeRuntime()"), "runtime store never crashes on a persistent-store initialization error")
expectSourceContains("Clipboard storage recovery mode", "runtime store reports persistent-store recovery mode for diagnostics")
