import SwiftUI


extension ClipboardMainView {
    var currentOperationNotice: String? {
        screenPinViewModel.operationNotice ?? viewModel.operationNotice
    }

    @ViewBuilder
    var mainContent: some View {
        let hasDisplayedItems = !viewModel.displayedItemIDs.isEmpty
        Group {
            if hasDisplayedItems {
                switch clipboardLayout {
                case .horizontal:
                    ClipboardHorizontalView(
                        viewModel: viewModel,
                        focusedField: focusedFieldState
                    )
                    .transition(listRevealTransition)
                case .vertical, .compact:
                    ClipboardVerticalListView(
                        viewModel: viewModel,
                        focusedField: focusedFieldState
                    )
                    .transition(listRevealTransition)
                }
            } else {
                ClipboardEmptyStateView(viewModel: viewModel)
                    .transition(.opacity)
            }
        }
        // 页面加载：骨架屏 → 列表 的 spring 过渡（对齐 Paste 的 spring + move/opacity 机制）
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: displayedItemIDs.isEmpty)
    }

    /// 历史列表从骨架屏浮现时的过渡：淡入 + 轻微放大 + 自底部上移；离开时仅淡出。
    private var listRevealTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.985)).combined(with: .move(edge: .bottom)),
            removal: .opacity
        )
    }

    func focusSearchField(collapseSelectionToInsertionPoint: Bool = false) {
        pendingListFocusGeneration &+= 1
        pendingListFocusRequest = nil
        pendingSearchFocusGeneration &+= 1
        let generation = pendingSearchFocusGeneration

        focusedField = nil
        searchService.isTextFieldFocused = false

        DispatchQueue.main.async {
            applySearchFieldFocusIfPossible(
                generation: generation,
                remainingAttempts: 3,
                collapseSelectionToInsertionPoint: collapseSelectionToInsertionPoint
            )
        }
    }

    func requestSearchFocus() {
        focusSearchField()
    }

    func requestListFocusPreservingSelection() {
        pendingListFocusGeneration &+= 1
        pendingSearchFocusGeneration &+= 1
        pendingListFocusRequest = nil
        focusedField = .clipList
        searchService.isTextFieldFocused = false
        resetPendingBlindTypedSearchInput()
        viewModel.ensureListSelection()
    }

    func activatePanelInputHandling() {
        isPanelKeyWindow = true
        viewModel.beginPresentation()
        viewModel.startKeyboardMonitoring()
        // 先启动面板级键盘监听，再启动盲打搜索，确保特殊按键优先被 ViewModel 消费。
        searchService.start()
        requestDefaultListFocus()
    }

    func deactivatePanelInputHandling() {
        isPanelKeyWindow = false
        pendingListFocusGeneration &+= 1
        pendingSearchFocusGeneration &+= 1
        pendingListFocusRequest = nil
        resetPendingBlindTypedSearchInput()
        searchService.stop()
        viewModel.stopKeyboardMonitoring()
        viewModel.endPresentation()
    }

    func handlePanelDidBecomeKey() {
        activatePanelInputHandling()
    }

    func handlePanelDidResignKey() {
        deactivatePanelInputHandling()
    }

    func requestDefaultListFocus() {
        pendingListFocusGeneration &+= 1
        pendingSearchFocusGeneration &+= 1
        pendingListFocusRequest = viewModel.settingsViewModel.autoFocusFirstItemOnPanelActivation
            ? .selectFirstItem
            : .preserveSelection
        focusedField = nil
        searchService.isTextFieldFocused = false
        resetPendingBlindTypedSearchInput()

        DispatchQueue.main.async {
            _ = applyPendingListFocusIfPossible()
        }
    }

    func requestListFocusAfterSearchExit() {
        pendingListFocusGeneration &+= 1
        pendingSearchFocusGeneration &+= 1
        let generation = pendingListFocusGeneration

        pendingListFocusRequest = .selectFirstItem
        focusedField = nil
        searchService.isTextFieldFocused = false
        resetPendingBlindTypedSearchInput()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard pendingListFocusGeneration == generation else { return }
            _ = applyPendingListFocusIfPossible()
        }
    }

}
