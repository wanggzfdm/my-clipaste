import SwiftUI

// MARK: - Click Paste Behavior Modifier

struct ClipboardItemActionModifier: ViewModifier {
    let item: ClipboardItem
    @ObservedObject var viewModel: ClipboardViewModel
    @AppStorage("singleClickPaste") private var singleClickPaste = false

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

extension View {
    /// Attach the configured click/paste behavior to any clipboard card.
    func clipboardItemActions(for item: ClipboardItem, viewModel: ClipboardViewModel) -> some View {
        self.modifier(ClipboardItemActionModifier(item: item, viewModel: viewModel))
    }
}

// MARK: - Card variant (fork Paste 2.1.5 click model)

struct ClipboardCardActionModifier: ViewModifier {
    let item: ClipboardItem
    @ObservedObject var viewModel: ClipboardViewModel
    @AppStorage("singleClickPaste") private var singleClickPaste = false
    @AppStorage("appTheme") private var appTheme: AppTheme = .system

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .modifier(
                ClipboardItemTapBehaviorModifier(
                    item: item,
                    viewModel: viewModel,
                    singleClickPaste: singleClickPaste,
                    usesPasteStyleClickModel: appTheme.panelVisualStyle == .paste
                )
            )
    }
}

private struct ClipboardItemTapBehaviorModifier: ViewModifier {
    let item: ClipboardItem
    @ObservedObject var viewModel: ClipboardViewModel
    let singleClickPaste: Bool
    var usesPasteStyleClickModel: Bool = false

    func body(content: Content) -> some View {
        if usesPasteStyleClickModel {
            // fork 2.1.5: single-click copy (or paste if preference), double-click force paste
            if singleClickPaste {
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
                    .simultaneousGesture(TapGesture().onEnded {
                        viewModel.handlePrimaryClickSelection(for: item.id)
                    })
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        viewModel.pasteToActiveApp(item: item, forceAutoPaste: true)
                    })
            }
        } else if singleClickPaste {
            content
                .simultaneousGesture(TapGesture().onEnded {
                    viewModel.pasteToActiveApp(item: item)
                })
        } else {
            content
                .simultaneousGesture(TapGesture().onEnded {
                    viewModel.handlePrimaryClickSelection(for: item.id)
                })
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    viewModel.pasteToActiveApp(item: item)
                })
        }
    }
}
