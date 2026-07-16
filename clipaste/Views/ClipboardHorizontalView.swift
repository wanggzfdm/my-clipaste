import SwiftUI

struct ClipboardHorizontalView: View {
    @ObservedObject var viewModel: ClipboardViewModel
    let items: [ClipboardItem]
    @FocusState var focusedField: ClipboardPanelFocusField?
    @AppStorage("requireCmdToDelete") private var requireCmdToDelete: Bool = false
    @AppStorage("singleClickPaste") private var singleClickPaste = true
    @State private var quickPasteIndexesByItemID: [UUID: Int] = [:]
    @State private var isListScrolling = false

    private let quickPasteCoordinateSpaceName = "ClipboardHorizontalQuickPasteSpace"

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewportProxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            ClipboardCardView(
                                item: item,
                                viewModel: viewModel,
                                quickPasteIndex: quickPasteIndexesByItemID[item.id]
                            )
                            .id(item.id)
                            .contentShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                            .help(pasteHelpText)
                            .clipboardQuickPasteVisibleFrame(
                                id: item.id,
                                sourceIndex: index,
                                coordinateSpaceName: quickPasteCoordinateSpaceName,
                                // Skip Preference fan-out while flinging — major LazyHStack cost.
                                isTrackingEnabled: viewModel.isQuickPasteModifierHeld && !isListScrolling
                            )
                        }
                    }
                    .padding(.horizontal, 33)
                    .padding(.top, 13)
                    .padding(.bottom, 5.5)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .background {
                    ScrollActivityObserver(isScrolling: $isListScrolling)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .disableAnimationsWhenScrolling(isListScrolling)
                .coordinateSpace(name: quickPasteCoordinateSpaceName)
                .onPreferenceChange(ClipboardQuickPasteVisibleFramePreferenceKey.self) { frames in
                    guard !isListScrolling else { return }
                    updateQuickPasteIndexes(
                        frames: frames,
                        viewportSize: viewportProxy.size
                    )
                }
                .focusable()
                .focusEffectDisabled()
                .focused($focusedField, equals: .clipList)
                .simultaneousGesture(TapGesture().onEnded {
                    focusedField = .clipList
                    if viewModel.isQuickLookActive {
                        viewModel.dismissQuickLook()
                    }
                })
                .onDeleteCommand {
                    guard !requireCmdToDelete else { return }
                    guard !viewModel.selectedItemIDs.isEmpty else { return }
                    viewModel.batchDelete()
                }
                .onAppear {
                    scrollToPrimarySelection(with: proxy, animated: false)
                }
                .onChange(of: viewModel.listScrollRequest) { _, request in
                    guard let request else { return }
                    scrollToItem(
                        with: proxy,
                        itemID: request.id,
                        animated: request.animated
                    )
                }
                .onChange(of: viewModel.isQuickPasteModifierHeld) { _, isHeld in
                    guard !isHeld, !quickPasteIndexesByItemID.isEmpty else { return }
                    quickPasteIndexesByItemID = [:]
                }
                .onChange(of: isListScrolling) { _, scrolling in
                    // Drop stale indexes when a fling starts; recompute after idle if needed.
                    if scrolling, !quickPasteIndexesByItemID.isEmpty {
                        quickPasteIndexesByItemID = [:]
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }

    private var pasteHelpText: Text {
        if singleClickPaste {
            Text("单击复制，双击粘贴到当前应用")
        } else {
            Text("双击粘贴到当前应用")
        }
    }

    private func updateQuickPasteIndexes(
        frames: [ClipboardQuickPasteVisibleFrame],
        viewportSize: CGSize
    ) {
        guard viewModel.isQuickPasteModifierHeld else {
            guard !quickPasteIndexesByItemID.isEmpty else { return }
            quickPasteIndexesByItemID = [:]
            return
        }

        let resolvedIndexes = ClipboardQuickPasteVisibleIndexResolver.resolve(
            frames: frames,
            viewportSize: viewportSize,
            axis: .horizontal,
            itemIDsInDisplayOrder: items.map(\.id)
        )

        guard resolvedIndexes != quickPasteIndexesByItemID else { return }
        quickPasteIndexesByItemID = resolvedIndexes
    }

    private func scrollToPrimarySelection(with proxy: ScrollViewProxy, animated: Bool) {
        guard let selectedID = viewModel.lastSelectedID ?? viewModel.selectedItemIDs.first else { return }
        scrollToItem(with: proxy, itemID: selectedID, animated: animated)
    }

    private func scrollToItem(with proxy: ScrollViewProxy, itemID: UUID, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8, blendDuration: 0.2)) {
                    proxy.scrollTo(itemID, anchor: .center)
                }
            } else {
                proxy.scrollTo(itemID, anchor: .center)
            }
        }
    }
}

#Preview {
    ClipboardHorizontalPreview()
}

private struct ClipboardHorizontalPreview: View {
    @FocusState private var focusedField: ClipboardPanelFocusField?

    var body: some View {
        ClipboardHorizontalView(
            viewModel: ClipboardViewModel(),
            items: [],
            focusedField: _focusedField
        )
    }
}
