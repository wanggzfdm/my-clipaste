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
                        // ID 驱动 ForEach：避免 enumerated 全表临时数组；sourceIndex 用 O(n) 字典一次构建。
                        let indexByID: [UUID: Int] = Dictionary(
                            uniqueKeysWithValues: viewModel.displayedItemIDs.enumerated().map { ($0.element, $0.offset) }
                        )
                        ForEach(viewModel.displayedItemIDs, id: \.self) { id in
                            if let item = viewModel.item(for: id) {
                                ClipboardCardView(
                                    item: item,
                                    viewModel: viewModel,
                                    isSelected: viewModel.selectedItemIDs.contains(id),
                                    searchHighlight: viewModel.activeSearchQuery,
                                    isQuickPasteModifierHeld: viewModel.isQuickPasteModifierHeld,
                                    isAIEnabled: viewModel.aiSettingsViewModel.isAIEnabled,
                                    quickPasteIndex: quickPasteIndexesByItemID[id],
                                    isListScrolling: isListScrolling
                                )
                                .equatable()
                                .id(id)
                                .contentShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                                .help(pasteHelpText)
                                .clipboardQuickPasteVisibleFrame(
                                    id: id,
                                    sourceIndex: indexByID[id] ?? 0,
                                    coordinateSpaceName: quickPasteCoordinateSpaceName,
                                    // Skip Preference fan-out while flinging — major LazyHStack cost.
                                    isTrackingEnabled: viewModel.isQuickPasteModifierHeld && !isListScrolling
                                )
                                .onAppear {
                                    viewModel.loadMoreIfNeeded(currentItemID: id)
                                }
                            }
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
                    if !scrollToFirstSearchResultIfNeeded(with: proxy) {
                        scrollToPrimarySelection(with: proxy, animated: false)
                    }
                }
                .onChange(of: viewModel.searchResultScrollGeneration) { _, _ in
                    scrollToFirstSearchResultIfNeeded(with: proxy)
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
            itemIDsInDisplayOrder: viewModel.displayedItemIDs
        )

        guard resolvedIndexes != quickPasteIndexesByItemID else { return }
        quickPasteIndexesByItemID = resolvedIndexes
    }

    private func scrollToPrimarySelection(with proxy: ScrollViewProxy, animated: Bool) {
        guard let selectedID = viewModel.lastSelectedID ?? viewModel.selectedItemIDs.first else { return }
        scrollToItem(with: proxy, itemID: selectedID, animated: animated)
    }

    @discardableResult
    private func scrollToFirstSearchResultIfNeeded(with proxy: ScrollViewProxy) -> Bool {
        guard let firstItemID = viewModel.displayedItemIDs.first,
              firstItemID == viewModel.searchResultScrollTargetID,
              viewModel.handledSearchResultScrollGeneration != viewModel.searchResultScrollGeneration else {
            return false
        }

        viewModel.handledSearchResultScrollGeneration = viewModel.searchResultScrollGeneration

        DispatchQueue.main.async {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(firstItemID, anchor: .leading)
            }
        }

        return true
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
