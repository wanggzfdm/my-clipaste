import SwiftUI

// MARK: - Click Behavior Modifier

struct ClipboardItemActionModifier: ViewModifier {
    let item: ClipboardItem
    @ObservedObject var viewModel: ClipboardViewModel
    @AppStorage("singleClickPaste") private var singleClickPaste = true

    func body(content: Content) -> some View {
        content
            // Ensure transparent areas are also tappable
            .contentShape(Rectangle())
            .modifier(ClipboardItemTapBehaviorModifier(
                item: item,
                viewModel: viewModel,
                singleClickPaste: singleClickPaste
            ))
    }
}

extension View {
    /// Attach the configured click behavior to any clipboard card.
    func clipboardItemActions(for item: ClipboardItem, viewModel: ClipboardViewModel) -> some View {
        self.modifier(ClipboardItemActionModifier(item: item, viewModel: viewModel))
    }
}

// MARK: - Optional-ViewModel variant for ClipboardCardView

/// Handles ClipboardCardView which has an optional viewModel and a legacy onSelect callback.
struct ClipboardCardActionModifier: ViewModifier {
    let item: ClipboardItem
    @ObservedObject var viewModel: ClipboardViewModel
    @AppStorage("singleClickPaste") private var singleClickPaste = true

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .modifier(ClipboardItemTapBehaviorModifier(
                item: item,
                viewModel: viewModel,
                singleClickPaste: singleClickPaste
            ))
    }
}

private struct ClipboardItemTapBehaviorModifier: ViewModifier {
    let item: ClipboardItem
    @ObservedObject var viewModel: ClipboardViewModel
    let singleClickPaste: Bool

    func body(content: Content) -> some View {
        if item.isObsidianSearchResult {
            content
                .simultaneousGesture(TapGesture().onEnded {
                    viewModel.handlePrimaryClickSelection(for: item.id)
                })
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    viewModel.openInObsidian(item: item)
                })
        } else if singleClickPaste {
            content
                .simultaneousGesture(TapGesture().onEnded {
                    viewModel.handlePrimaryClickSelection(for: item.id)
                    viewModel.copyToClipboard(item: item)
                })
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    viewModel.pasteToActiveApp(item: item, forceAutoPaste: true)
                })
        } else {
            content
                // Make selection feel instant. Double-click still fires paste, but single-click
                // no longer waits for the double-click recognition window to expire.
                .simultaneousGesture(TapGesture().onEnded {
                    viewModel.handlePrimaryClickSelection(for: item.id)
                })
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    viewModel.pasteToActiveApp(item: item, forceAutoPaste: true)
                })
        }
    }
}
