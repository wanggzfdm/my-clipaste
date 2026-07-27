import AppKit
import Combine
import SwiftUI

extension ClipboardViewModel {
    func beginPresentation() {
        let wasAlreadyActive = isPanelPresentationActive
        isPanelPresentationActive = true

        // Only reset search on the initial presentation, not when regaining focus
        // while already active. This preserves search state when the panel
        // regains focus during an active search.
        if wasAlreadyActive == false {
            resetSearchForPresentationIfNeeded()
        }

        guard wasAlreadyActive == false else { return }

        if hasPreparedPanelData == false {
            shouldResetSelectionToFirstDisplayedItem = true
            preparePanelDataIfNeeded()
            return
        }

        guard needsReloadOnNextPresentation else { return }
        needsReloadOnNextPresentation = false

        // 已有 scope 快照/当前 displayed 时：先画再静默 visibleFirst 合并，避免重开空白。
        if displayedItems.isEmpty, items.isEmpty {
            isInitialHistoryLoading = true
        }
        shouldResetSelectionToFirstDisplayedItem = displayedItems.isEmpty
        loadData(mode: displayedItems.isEmpty ? .fullRefresh : .visibleFirst)
        loadCustomGroups()
    }

    func preparePanelDataIfNeeded() {
        guard hasPreparedPanelData == false else { return }

        hasPreparedPanelData = true
        hydrateFromWarmCacheIfAvailable()
        loadData(mode: .visibleFirst)
        loadCustomGroups()
    }

    /// Synchronously primes list content for the panel open hot path.
    /// Prefer warm cache / already-loaded items so `showPanel` can order front immediately.
    func primePanelContentForImmediatePresentation() {
        // 优先恢复上次关闭时的 scope 快照（含自定义分组）
        restoreScopeSnapshotIfPossible()
        preparePanelDataIfNeeded()
        if items.isEmpty || displayedItems.isEmpty {
            hydrateFromWarmCacheIfAvailable()
        }
        if displayedItems.isEmpty, hasLoadedFullHistory == false {
            isInitialHistoryLoading = true
        }
    }

    /// Background reconcile after the panel is already visible.
    /// Avoids blocking `makeKeyAndOrderFront` on pasteboard capture or DB reads.
    func refreshHistoryAfterPresentationIfNeeded() async {
        if needsReloadOnNextPresentation {
            needsReloadOnNextPresentation = false
            shouldResetSelectionToFirstDisplayedItem = displayedItems.isEmpty
            // 有快照内容时用 visibleFirst 合并，避免冲掉首屏
            loadData(mode: displayedItems.isEmpty ? .fullRefresh : .visibleFirst)
            loadCustomGroups()
            return
        }

        if items.isEmpty || (displayedItems.isEmpty && selectedGroupId != nil) {
            await refreshFirstHistoryPageForPresentation()
        }
    }

    func refreshFirstHistoryPageForPresentation() async {
        preparePanelDataIfNeeded()

        dataLoadGeneration &+= 1
        let generation = dataLoadGeneration
        historyLoadTask?.cancel()

        let pageSize = pagination.pageSize > 0 ? pagination.pageSize : Self.historyPageSize
        pagination = HistoryPaginationState(
            loadedCount: 0,
            pageSize: pageSize,
            hasMore: true,
            isLoading: true,
            generation: generation,
            activeQuery: ""
        )

        let firstPage = await StorageManager.shared.fetchItemsPage(
            searchText: "",
            fetchLimit: pageSize,
            offset: 0
        )

        applyInitialHistoryPage(
            firstPage,
            generation: generation,
            mode: .visibleFirst
        )
        pagination.loadedCount = firstPage.count
        pagination.hasMore = firstPage.count == pageSize
        pagination.isLoading = false
        loadedHistoryCount = items.count
        hasLoadedFullHistory = pagination.hasMore == false
        isInitialHistoryLoading = false
        isLoadingMoreHistory = false
    }

    func endPresentation() {
        isPanelPresentationActive = false
        dismissAutoPreviewIfNeeded()
        releaseTransientResourcesAfterPanelClose()
    }

    /// 面板关闭后收缩内存:释放高分预览图与 QuickLook 锚点,
    /// 并把全量历史裁剪回 warm cache 首屏规模。
    /// 下次打开由 needsReloadOnNextPresentation 触发全量后台重载,
    /// 首屏内容仍旧即时可见(裁剪保留的头部 = warm cache 内容)。
    private func releaseTransientResourcesAfterPanelClose() {
        highResImage = nil
        quickLookAnchorFramesByItemID.removeAll()

        // 先拍当前 scope 快照，重开时立刻可画
        let snapshotLimit = max(ClipboardHistoryWarmCache.defaultLimit, Self.displayMaterializeWindowSize)
        lastScopeSnapshot = PanelScopeSnapshot(
            filter: currentFilter,
            builtInGroup: selectedBuiltInGroup,
            groupID: selectedGroupId,
            items: Array(displayedItems.prefix(snapshotLimit)),
            displayedIDs: Array(displayedItemIDs.prefix(snapshotLimit))
        )

        let retainCount = ClipboardHistoryWarmCache.defaultLimit
        // 即使总数不大，也标记下次需要 reconcile；有 snapshot 时首屏仍即时。
        needsReloadOnNextPresentation = true

        guard items.count > retainCount else {
            // 仍取消进行中的 bulk load，避免关面板后继续灌内存
            if historyLoadTask != nil {
                historyLoadTask?.cancel()
                historyLoadTask = nil
                dataLoadGeneration &+= 1
                isBulkHistoryLoading = false
                isLoadingMoreHistory = false
            }
            return
        }

        historyLoadTask?.cancel()
        historyLoadTask = nil
        dataLoadGeneration &+= 1
        isBulkHistoryLoading = false
        isLoadingMoreHistory = false
        isInitialHistoryLoading = false

        // 裁剪时优先保留当前 scope 命中项 + 全局头，避免分组重开变空
        let keepIDs = Set(lastScopeSnapshot?.displayedIDs ?? [])
        let scoped = items.filter { keepIDs.contains($0.id) }
        let head = Array(items.prefix(retainCount))
        let merged = deduplicatedItemsPreservingOrder(scoped + head)
        let retained = Array(merged.prefix(max(retainCount, min(scoped.count, snapshotLimit))))

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            replaceItems(retained, enqueueLinkMetadata: false)
            if let snap = lastScopeSnapshot, snap.displayedIDs.isEmpty == false {
                // 恢复 scope 显示 ID（可能比 retained 更贴当前分组）
                let available = Set(retained.map(\.id))
                let scopedIDs = snap.displayedIDs.filter { available.contains($0) }
                if scopedIDs.isEmpty == false {
                    publishDisplayedItemIDs(scopedIDs)
                } else {
                    refreshDisplayedItemsFromCurrentScope()
                }
            } else {
                refreshDisplayedItemsFromCurrentScope()
            }
            clampSelectionToDisplayedItems()
        }

        hasLoadedFullHistory = false
        loadedHistoryCount = items.count
    }

    func setupDataSubscriptions() {
        NotificationCenter.default.publisher(for: .clipboardDataDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.hasPreparedPanelData else { return }
                guard self.isPanelPresentationActive else {
                    self.needsReloadOnNextPresentation = true
                    return
                }
                // 真分页后 fullRefresh 也只拉首屏；用 visibleFirst 保留窗口内已有项，避免整表空白。
                self.loadData(mode: .visibleFirst)
                self.loadCustomGroups()
                self.needsReloadOnNextPresentation = false
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .didFinishDataMigration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.hasPreparedPanelData else { return }
                guard self.isPanelPresentationActive else {
                    self.needsReloadOnNextPresentation = true
                    return
                }
                self.needsReloadOnNextPresentation = true
            }
            .store(in: &cancellables)
    }

    func setupWarmCacheSubscription() {
        NotificationCenter.default.publisher(for: .clipboardWarmCacheDidChange)
            .compactMap(\.clipboardWarmCacheChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self else { return }
                guard change.routeKey == ClipboardRuntimeStore.shared.rootIdentity else { return }
                self.hydrateFromWarmCacheIfAvailable()
            }
            .store(in: &cancellables)
    }

    func reloadPanelDataAfterMigration() {
        loadData()
        loadCustomGroups()
    }

    func resetSearchForPresentationIfNeeded() {
        guard settingsViewModel.clearSearchOnPanelActivation else { return }
        guard !searchInput.isEmpty || !activeSearchQuery.isEmpty else { return }

        searchInput = ""
        activeSearchQuery = ""
    }

    func triggerAutoCleanup() {
        let retentionRaw = UserDefaults.standard.string(forKey: "historyRetention") ?? HistoryRetention.oneMonth.rawValue
        guard let retention = HistoryRetention(rawValue: retentionRaw),
              let expirationDate = retention.expirationDate else { return }

        Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            StorageManager.shared.performAutoCleanup(before: expirationDate)
        }
    }

    func hydrateFromWarmCacheIfAvailable() {
        // 搜索态不 hydrate，避免冲掉搜索结果
        guard searchInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              activeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        // 先尝试 scope 快照（含分组/智能分类）
        if restoreScopeSnapshotIfPossible() {
            return
        }

        let routeKey = ClipboardRuntimeStore.shared.rootIdentity
        guard let cachedItems = ClipboardHistoryWarmCache.shared.snapshot(for: routeKey) else {
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if items.isEmpty || hasPreparedPanelData == false {
                applyLoadedItems(cachedItems)
                loadedHistoryCount = cachedItems.count
                hasLoadedFullHistory = cachedItems.count < ClipboardHistoryWarmCache.defaultLimit
                // 允许在非「全部」scope 下 hydrate 后再按当前 scope 过滤
                refreshDisplayedItemsFromCurrentScope()
                return
            }

            // Keep an already-loaded list, but merge a fresher warm-cache head
            guard let cachedFirst = cachedItems.first else { return }
            if items.first?.contentHash != cachedFirst.contentHash {
                applyOptimisticCapture(cachedFirst, silent: true)
            }
        }
    }

    /// 若快照与当前 scope 匹配，静默恢复首屏。返回是否恢复成功。
    @discardableResult
    func restoreScopeSnapshotIfPossible() -> Bool {
        guard let snap = lastScopeSnapshot else { return false }
        guard snap.filter == currentFilter,
              snap.builtInGroup == selectedBuiltInGroup,
              snap.groupID == selectedGroupId else {
            return false
        }
        guard snap.items.isEmpty == false || snap.displayedIDs.isEmpty == false else {
            return false
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if items.isEmpty {
                replaceItems(snap.items, enqueueLinkMetadata: false)
            } else {
                mergeItems(snap.items, prepend: true, enqueueLinkMetadata: false)
            }
            let available = Set(items.map(\.id))
            let ids = snap.displayedIDs.filter { available.contains($0) }
            if ids.isEmpty {
                refreshDisplayedItemsFromCurrentScope()
            } else {
                publishDisplayedItemIDs(ids)
            }
            isInitialHistoryLoading = false
        }
        return displayedItems.isEmpty == false || displayedItemIDs.isEmpty == false
    }
}
