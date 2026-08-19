import AppKit
import Combine
import SwiftUI

extension ClipboardViewModel {
    func beginPresentation() {
        let wasAlreadyActive = isPanelPresentationActive
        isPanelPresentationActive = true

        // Only reset search / group on the initial presentation, not when regaining focus
        // while already active. This preserves search state when the panel
        // regains focus during an active search.
        if wasAlreadyActive == false {
            resetSearchForPresentationIfNeeded()
            // 不再强制切回「全部」：保留用户上次所在的分组，避免重新呼出面板时一闪。
            // 分页游标仅在 scope 发生变化时才需要重置，此处无需处理。
        }

        guard wasAlreadyActive == false else { return }

        if hasPreparedPanelData == false {
            shouldResetSelectionToFirstDisplayedItem = true
            preparePanelDataIfNeeded()
            return
        }

        guard needsReloadOnNextPresentation else {
            // 即使不需要整表重载，也确保当前 scope 的展示是最新的。
            refreshCurrentScopeDisplayedItems()
            shouldResetSelectionToFirstDisplayedItem = true
            return
        }
        needsReloadOnNextPresentation = false

        // 默认分组下：先画再静默 visibleFirst 合并，避免重开空白。
        if displayedItems.isEmpty, items.isEmpty {
            isInitialHistoryLoading = true
        }
        shouldResetSelectionToFirstDisplayedItem = true
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
    /// Synchronously primes list content for the panel open hot path.
    /// Prefer warm cache / already-loaded items so `showPanel` can order front immediately.
    func primePanelContentForImmediatePresentation() {
        // 不再强制切回「全部」：保留上次的分组状态，避免重开面板时一闪。

        // 尝试恢复上次 scope 的快照（不限于「全部」）；快照匹配当前 scope 时直接恢复首屏。
        if isSnapshotForCurrentScope(lastScopeSnapshot) {
            _ = restoreScopeSnapshotIfPossible()
        } else {
            lastScopeSnapshot = nil
        }

        preparePanelDataIfNeeded()
        if items.isEmpty || displayedItems.isEmpty {
            hydrateFromWarmCacheIfAvailable()
        }
        refreshCurrentScopeDisplayedItems()
        if displayedItems.isEmpty, hasLoadedFullHistory == false {
            isInitialHistoryLoading = true
        }
        shouldResetSelectionToFirstDisplayedItem = true
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
        ClipboardImagePipeline.shared.invalidateAll()
        ListRenderEngine.shared.invalidateAll()
        AppIconManager.shared.invalidateAll()

        // 保存当前 scope 的首屏快照：下次打开直接恢复，不强制切回「全部」。
        let snapshotLimit = max(ClipboardHistoryWarmCache.defaultLimit, Self.displayMaterializeWindowSize)
        let snapshotItems = Array(displayedItems.prefix(snapshotLimit))
        let snapshotIDs = Array(displayedItemIDs.prefix(snapshotLimit))
        lastScopeSnapshot = PanelScopeSnapshot(
            filter: currentFilter,
            builtInGroup: selectedBuiltInGroup,
            groupID: selectedGroupId,
            items: snapshotItems,
            displayedIDs: snapshotIDs
        )
        // 保留当前 scope 的缓存，清理其它 scope 以释放内存。
        let currentKey = activeScopeCacheKey
        scopeCache.removeAll(keeping: { $0 == currentKey })

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

        // 裁剪时优先保留全局头（下次打开默认「全部」），再夹带当前可见项避免丢数据。
        let keepIDs = Set(lastScopeSnapshot?.displayedIDs ?? [])
        let head = Array(items.prefix(retainCount))
        let scoped = items.filter { keepIDs.contains($0.id) }
        let merged = deduplicatedItemsPreservingOrder(head + scoped)
        let retained = Array(merged.prefix(max(retainCount, min(scoped.count, snapshotLimit))))

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            replaceItems(retained, enqueueLinkMetadata: false)
            // 关闭后保留当前分组状态，下次打开恢复到同一分组。
            // 不再强制重置为「全部」。
            activeScopeCacheKey = scopeCacheKey(
                query: activeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                groupID: selectedGroupId,
                type: currentFilter,
                builtInGroup: selectedBuiltInGroup
            )
            if let snap = lastScopeSnapshot, snap.displayedIDs.isEmpty == false {
                let available = Set(retained.map(\.id))
                let headIDs = snap.displayedIDs.filter { available.contains($0) }
                if headIDs.isEmpty == false {
                    publishDisplayedItemIDs(headIDs)
                } else {
                    publishAllScopeDisplayedItems()
                }
            } else {
                publishAllScopeDisplayedItems()
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

        // 若快照匹配当前 scope，优先用快照恢复首屏（不限于「全部」）。
        if isSnapshotForCurrentScope(lastScopeSnapshot), restoreScopeSnapshotIfPossible() {
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

    /// 每次打开面板：切回第一个分组（全部）。
    func resetToDefaultGroupForPresentation() {
        let alreadyDefault =
            currentFilter == nil
            && selectedBuiltInGroup == nil
            && selectedGroupId == nil

        currentFilter = nil
        selectedBuiltInGroup = nil
        selectedGroupId = nil

        // 分页游标也回到「全部」，避免沿用分组/类型/收藏的 offset。
        if pagination.scopeGroupId != nil
            || pagination.scopeTypeRawValue != nil
            || pagination.scopePinnedOnly
            || pagination.activeQuery.isEmpty == false {
            let pageSize = pagination.pageSize > 0 ? pagination.pageSize : Self.historyPageSize
            pagination = HistoryPaginationState(
                loadedCount: items.count,
                pageSize: pageSize,
                hasMore: hasLoadedFullHistory == false,
                isLoading: false,
                generation: dataLoadGeneration,
                activeQuery: "",
                scopeGroupId: nil,
                scopeTypeRawValue: nil,
                scopePinnedOnly: false
            )
        }

        if alreadyDefault == false {
            filterGeneration &+= 1
        }
    }

    /// 打开后确保当前 scope 的列表展示是最新的。
    func refreshCurrentScopeDisplayedItems() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            refreshDisplayedItemsFromCurrentScope()
        }
    }

    private func isSnapshotForCurrentScope(_ snap: PanelScopeSnapshot?) -> Bool {
        guard let snap else { return false }
        return snap.filter == currentFilter
            && snap.builtInGroup == selectedBuiltInGroup
            && snap.groupID == selectedGroupId
    }
}
