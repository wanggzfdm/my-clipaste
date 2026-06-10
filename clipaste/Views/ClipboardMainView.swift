import SwiftUI

struct ClipboardMainView: View {
    private enum PendingListFocusRequest {
        case preserveSelection
        case selectFirstItem
    }

    @Environment(ClipboardRuntimeStore.self) private var runtimeStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme
    @StateObject var viewModel: ClipboardViewModel
    @AppStorage("clipboardLayout") private var clipboardLayout: AppLayoutMode = .horizontal
    @AppStorage("appTheme") private var appTheme: AppTheme = .system
    @FocusState private var focusedField: ClipboardPanelFocusField?

    @State private var isPanelKeyWindow = false
    @State private var pendingListFocusRequest: PendingListFocusRequest?
    @State private var pendingListFocusGeneration: UInt = 0
    @State private var pendingSearchFocusGeneration: UInt = 0
    @State private var pendingBlindTypedSearchText = ""
    @State private var pendingBlindTypedBaseSearchText: String?
    @State private var pendingBlindTypedSearchEvents: [NSEvent] = []
    private let searchService = TypeToSearchService.shared

    @MainActor
    init() {
        _viewModel = StateObject(wrappedValue: ClipboardViewModel())
    }

    @MainActor
    init(viewModel: ClipboardViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        configuredContent
    }

    @ViewBuilder
    private var panelLayoutContent: some View {
        Group {
            if clipboardLayout == .horizontal {
                VStack(spacing: 0) {
                    ClipboardHeaderView(viewModel: viewModel, focusedField: _focusedField)
                    mainContent
                }
            } else {
                VStack(spacing: 0) {
                    ClipboardHeaderView(viewModel: viewModel, focusedField: _focusedField)
                    mainContent
                    historyPreviewFooter
                }
            }
        }
    }

    private var configuredContent: some View {
        panelLayoutContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
            .background(
                panelBackground
            )
            .background(
                ClipboardPanelWindowObserver(
                    onWindowDidBecomeKey: handlePanelDidBecomeKey,
                    onWindowDidResignKey: handlePanelDidResignKey
                )
            )
            .background(WindowAppearanceObserver(theme: appTheme))
            .background(ClipboardQuickLookWindowPresenter(viewModel: viewModel))
            .overlay(alignment: .top) {
                if let operationNotice = viewModel.operationNotice {
                    ClipboardOperationNoticeView(message: operationNotice)
                        .padding(.top, (clipboardLayout == .vertical || clipboardLayout == .compact) ? 72 : 52)
                        .padding(.horizontal, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
            .ignoresSafeArea()
            .animation(.spring(response: 0.24, dampingFraction: 0.9), value: viewModel.operationNotice != nil)
            .onChange(of: clipboardLayout) {
                // Only resize the AppKit panel after the AppStorage-backed SwiftUI layout
                // has already switched, avoiding a one-frame stretch of the old content.
                NotificationCenter.default.post(
                    name: .clipboardLayoutModeChanged,
                    object: clipboardLayout
                )
                requestDefaultSearchFocus()
            }
            .onChange(of: focusedField) { _, newValue in
                viewModel.panelFocusField = newValue

                guard newValue == .searchBar else {
                    searchService.isTextFieldFocused = false
                    viewModel.isSearchCompositionActive = false
                    return
                }

                DispatchQueue.main.async {
                    searchService.isTextFieldFocused = isActiveTextInputResponder
                    syncSearchCompositionState()
                }
            }
            .onChange(of: displayedItemIDs) { _, _ in
                if applyPendingListFocusIfPossible() {
                    return
                }

                if focusedField == .clipList, viewModel.isSearchFilteringActive == false {
                    viewModel.ensureListSelection()
                }
            }
            .onChange(of: viewModel.searchInput) { oldValue, newValue in
                syncSearchCompositionState()
                DispatchQueue.main.async {
                    syncSearchCompositionState()
                }

                guard !oldValue.isEmpty, newValue.isEmpty else { return }
                requestListFocusAfterSearchExit()
            }
            .onAppear {
                viewModel.preparePanelDataIfNeeded()
                searchService.onInterceptedKey = { [weak viewModel] event in
                    guard let viewModel else { return false }

                    guard viewModel.shouldStartTypeToSearch(with: event),
                          let acceptedInput = viewModel.acceptedSearchInput(from: event) else {
                        return false
                    }

                    bufferBlindTypedSearchInput(acceptedInput, event: event)
                    focusSearchField(collapseSelectionToInsertionPoint: true)
                    return true
                }
                requestDefaultSearchFocus()
            }
            .onDisappear {
                searchService.onInterceptedKey = nil
                deactivatePanelInputHandling()
            }
            // ── ⌘, 意图通知 → 调用 SwiftUI 原生 openSettings ───────────
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsIntent)) { _ in
                SettingsWindowCoordinator.open {
                    openSettings()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusSearchFieldIntent)) { _ in
                requestSearchFocus()
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusListIntent)) { _ in
                requestListFocusPreservingSelection()
            }
            .sheet(item: titleEditorItemBinding, onDismiss: viewModel.dismissTitleEditor) { item in
                ClipboardItemTitleEditorSheet(item: item) { title in
                    viewModel.saveCustomTitle(for: item, title: title)
                }
            }
    }

    @ViewBuilder
    private var panelBackground: some View {
        if clipboardLayout == .horizontal {
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)

                LinearGradient(
                    colors: [
                        (colorScheme == .dark ? Color.black : Color(nsColor: .windowBackgroundColor))
                            .opacity(colorScheme == .dark ? 0.26 : 0.26),
                        (colorScheme == .dark ? Color.black : Color(nsColor: .windowBackgroundColor))
                            .opacity(colorScheme == .dark ? 0.14 : 0.12)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.025 : 0.22),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        } else {
            WindowBackgroundGlass()
        }
    }

    private var panelCornerRadius: CGFloat {
        (clipboardLayout == .vertical || clipboardLayout == .compact) ? 14 : 26
    }

    @ViewBuilder
    private var mainContent: some View {
        SearchResultsTransitionContainer(
            isActive: viewModel.isSearchFilteringActive,
            token: searchTransitionToken
        ) {
            if displayedItems.isEmpty {
                ClipboardEmptyStateView(viewModel: viewModel)
            } else {
                switch clipboardLayout {
                case .horizontal:
                    ClipboardHorizontalView(
                        viewModel: viewModel,
                        items: displayedItems,
                        focusedField: _focusedField
                    )
                case .vertical, .compact:
                    ClipboardVerticalListView(
                        viewModel: viewModel,
                        items: displayedItems,
                        focusedField: _focusedField
                    )
                }
            }
        }
    }

    private func focusSearchField(collapseSelectionToInsertionPoint: Bool = false) {
        if focusedField == .searchBar, isActiveTextInputResponder {
            searchService.isTextFieldFocused = true
            if collapseSelectionToInsertionPoint {
                collapseActiveTextSelectionToInsertionPoint()
            }
            return
        }

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

    private func requestSearchFocus() {
        focusSearchField()
    }

    private func requestListFocusPreservingSelection() {
        pendingListFocusGeneration &+= 1
        pendingSearchFocusGeneration &+= 1
        pendingListFocusRequest = nil
        focusedField = .clipList
        searchService.isTextFieldFocused = false
        resetPendingBlindTypedSearchInput()
        viewModel.ensureListSelection()
    }

    private func activatePanelInputHandling() {
        isPanelKeyWindow = true
        viewModel.beginPresentation()
        viewModel.startKeyboardMonitoring()
        // 先启动面板级键盘监听，再启动盲打搜索，确保特殊按键优先被 ViewModel 消费。
        searchService.start()
        requestDefaultSearchFocus()
    }

    private func deactivatePanelInputHandling() {
        isPanelKeyWindow = false
        pendingListFocusGeneration &+= 1
        pendingSearchFocusGeneration &+= 1
        pendingListFocusRequest = nil
        resetPendingBlindTypedSearchInput()
        searchService.stop()
        viewModel.stopKeyboardMonitoring()
        viewModel.endPresentation()
    }

    private func handlePanelDidBecomeKey() {
        activatePanelInputHandling()
    }

    private func handlePanelDidResignKey() {
        deactivatePanelInputHandling()
    }

    private func requestDefaultSearchFocus() {
        pendingListFocusGeneration &+= 1
        pendingListFocusRequest = nil
        resetPendingBlindTypedSearchInput()

        if displayedItems.isEmpty == false {
            viewModel.ensureListSelection()
        }

        if focusedField == .searchBar, isActiveTextInputResponder {
            searchService.isTextFieldFocused = true
            return
        }

        focusSearchField()
    }

    private func requestListFocusAfterSearchExit() {
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

    private var titleEditorItemBinding: Binding<ClipboardItem?> {
        Binding(
            get: { viewModel.titleEditorItem },
            set: { newValue in
                if let newValue {
                    viewModel.titleEditorItem = newValue
                } else {
                    viewModel.dismissTitleEditor()
                }
            }
        )
    }

    @discardableResult
    private func applyPendingListFocusIfPossible() -> Bool {
        guard let pendingListFocusRequest else { return false }
        guard isPanelKeyWindow else { return false }
        guard !displayedItems.isEmpty else { return false }
        guard viewModel.isSearchFilteringActive == false else {
            self.pendingListFocusRequest = nil
            return false
        }

        switch pendingListFocusRequest {
        case .preserveSelection:
            viewModel.ensureListSelection()
        case .selectFirstItem:
            viewModel.selectFirstDisplayedItem()
        }
        focusedField = .clipList
        self.pendingListFocusRequest = nil
        return true
    }

    private func applySearchFieldFocusIfPossible(
        generation: UInt,
        remainingAttempts: Int,
        collapseSelectionToInsertionPoint: Bool
    ) {
        guard pendingSearchFocusGeneration == generation else { return }
        guard isPanelKeyWindow else { return }

        focusedField = .searchBar

        DispatchQueue.main.async {
            guard pendingSearchFocusGeneration == generation else { return }
            guard isPanelKeyWindow else { return }

            if isActiveTextInputResponder {
                if collapseSelectionToInsertionPoint {
                    collapseActiveTextSelectionToInsertionPoint()
                }
                searchService.isTextFieldFocused = true
                replayPendingBlindTypedSearchEventsIfNeeded()

                DispatchQueue.main.async {
                    finalizePendingBlindTypedSearchInputIfNeeded()
                }
                return
            }

            guard remainingAttempts > 0 else { return }

            focusedField = nil
            searchService.isTextFieldFocused = false

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                applySearchFieldFocusIfPossible(
                    generation: generation,
                    remainingAttempts: remainingAttempts - 1,
                    collapseSelectionToInsertionPoint: collapseSelectionToInsertionPoint
                )
            }
        }
    }

    private func bufferBlindTypedSearchInput(_ input: String, event: NSEvent) {
        if pendingBlindTypedBaseSearchText == nil {
            pendingBlindTypedBaseSearchText = viewModel.searchInput
        }

        pendingBlindTypedSearchText.append(input)
        pendingBlindTypedSearchEvents.append(event)
    }

    private func replayPendingBlindTypedSearchEventsIfNeeded() {
        guard let textView = activeTextInputView else { return }
        guard !pendingBlindTypedSearchEvents.isEmpty else { return }

        let pendingEvents = pendingBlindTypedSearchEvents
        pendingBlindTypedSearchEvents.removeAll()
        textView.interpretKeyEvents(pendingEvents)
    }

    private func finalizePendingBlindTypedSearchInputIfNeeded() {
        guard let baseSearchText = pendingBlindTypedBaseSearchText else { return }
        guard !pendingBlindTypedSearchText.isEmpty else {
            pendingBlindTypedBaseSearchText = nil
            return
        }

        if let textView = activeTextInputView, textView.hasMarkedText() {
            resetPendingBlindTypedSearchInput()
            return
        }

        let expectedSearchText = baseSearchText + pendingBlindTypedSearchText
        let currentSearchText = viewModel.searchInput

        if currentSearchText == expectedSearchText || currentSearchText != baseSearchText {
            resetPendingBlindTypedSearchInput()
            return
        }

        viewModel.searchInput = expectedSearchText
        resetPendingBlindTypedSearchInput()
    }

    private func resetPendingBlindTypedSearchInput() {
        pendingBlindTypedSearchText = ""
        pendingBlindTypedBaseSearchText = nil
        pendingBlindTypedSearchEvents.removeAll()
    }

    private func collapseActiveTextSelectionToInsertionPoint() {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else {
            return
        }

        guard !textView.hasMarkedText() else {
            return
        }

        let stringLength = textView.string.count
        textView.setSelectedRange(NSRange(location: stringLength, length: 0))
    }

    private func syncSearchCompositionState() {
        let isComposing = focusedField == .searchBar && (activeTextInputView?.hasMarkedText() == true)
        if viewModel.isSearchCompositionActive != isComposing {
            viewModel.isSearchCompositionActive = isComposing
        }
    }

    private var isActiveTextInputResponder: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else {
            return false
        }

        return responder is NSTextView || responder is NSTextField
    }

    private var activeTextInputView: NSTextView? {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
            return textView
        }

        if let textField = NSApp.keyWindow?.firstResponder as? NSTextField,
           let fieldEditor = textField.window?.fieldEditor(true, for: textField) as? NSTextView {
            return fieldEditor
        }

        return nil
    }

    private var displayedItems: [ClipboardItem] {
        viewModel.displayedItems
    }

    private var displayedItemIDs: [UUID] {
        viewModel.displayedItemIDs
    }

    private var searchTransitionToken: SearchResultsTransitionToken {
        SearchResultsTransitionToken(
            query: viewModel.activeSearchQuery,
            itemIDs: displayedItemIDs
        )
    }

    @ViewBuilder
    private var historyPreviewFooter: some View {
        HStack {
            Spacer()

            Text("\(displayedItems.count) Items")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .padding(.top, 4)
        .background(.regularMaterial)
    }
}

#Preview {
    ClipboardMainView()
        .environmentObject(AppPreferencesStore.shared)
        .environment(ClipboardRuntimeStore.shared)
}
