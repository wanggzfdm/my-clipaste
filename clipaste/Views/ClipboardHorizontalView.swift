import AppKit
import QuartzCore
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
    /// 列表内容左缘锚点：scrollTo 首卡 leading 会吃掉左边距，改滚到此锚点以保留与分组一致的左侧空白。
    private static let leadingEdgeAnchorID = "clipboard-horizontal-leading-edge"

    private var shouldKillListAnimations: Bool {
        isListScrolling || viewModel.suppressListAnimations
    }

    private var horizontalContentMargin: CGFloat { 33 }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewportProxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    // epoch 变化时整树重建，避免 ForEach 对「新 ID」做水平 insertion 动画
                    LazyHStack(alignment: .top, spacing: 20) {
                        // 左缘哨兵：分组切换后滚回列表起点时用，避免首卡 .leading 贴边吃掉边距
                        Color.clear
                            .frame(width: 0, height: 0)
                            .id(Self.leadingEdgeAnchorID)

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
                                    isTrackingEnabled: viewModel.isQuickPasteModifierHeld && !isListScrolling
                                )
                                .onAppear {
                                    viewModel.loadMoreIfNeeded(currentItemID: id)
                                }
                                .transition(.identity)
                            }
                        }
                    }
                    .id(viewModel.listContentEpoch)
                    .animation(nil, value: viewModel.listContentEpoch)
                    .animation(nil, value: viewModel.selectedGroupId)
                    .animation(nil, value: viewModel.currentFilter)
                    .animation(nil, value: viewModel.selectedBuiltInGroup)
                    .padding(.top, 13)
                    .padding(.bottom, 5.5)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
                // 边距放在 scroll content margins：scrollTo 卡片时仍保留与其它分组一致的左右空白
                .contentMargins(.horizontal, horizontalContentMargin, for: .scrollContent)
                .disableAnimationsWhenScrolling(shouldKillListAnimations)
                .background {
                    ScrollActivityObserver(isScrolling: $isListScrolling)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
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
                .onChange(of: viewModel.listContentEpoch) { _, _ in
                    // scope 重建后滚回内容左缘（含 contentMargins），不要 scrollTo 首卡 leading 贴边
                    scrollToLeadingEdge(with: proxy)
                }
                .onChange(of: viewModel.isQuickPasteModifierHeld) { _, isHeld in
                    guard !isHeld, !quickPasteIndexesByItemID.isEmpty else { return }
                    quickPasteIndexesByItemID = [:]
                }
                .onChange(of: isListScrolling) { _, scrolling in
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
        scrollToItem(with: proxy, itemID: firstItemID, animated: false, anchor: .leading)
        return true
    }

    private func scrollToLeadingEdge(with proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            transaction.animation = nil
            withTransaction(transaction) {
                proxy.scrollTo(Self.leadingEdgeAnchorID, anchor: .leading)
            }
            CATransaction.commit()
        }
    }

    private func scrollToItem(
        with proxy: ScrollViewProxy,
        itemID: UUID,
        animated: Bool,
        anchor: UnitPoint = .center
    ) {
        // 滚到「当前列表第一张」且无动画：视为回到列表起点，保留左侧空白。
        let isListHead = itemID == viewModel.displayedItemIDs.first
        if animated == false, isListHead {
            scrollToLeadingEdge(with: proxy)
            return
        }

        DispatchQueue.main.async {
            if animated {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8, blendDuration: 0.2)) {
                    proxy.scrollTo(itemID, anchor: anchor)
                }
                return
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            transaction.animation = nil
            withTransaction(transaction) {
                proxy.scrollTo(itemID, anchor: anchor)
            }
            CATransaction.commit()
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
