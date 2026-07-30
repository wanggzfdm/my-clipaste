import AppKit
import Combine
import SwiftUI

extension ClipboardViewModel {
    var isSearchFilteringActive: Bool {
        !searchInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !activeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func setupFilterPipeline() {
        let searchQueries = Publishers.CombineLatest($searchInput, $isSearchCompositionActive)
            .map { query, isComposing -> AnyPublisher<String, Never> in
                if isComposing {
                    return Empty()
                        .eraseToAnyPublisher()
                }

                let isEffectivelyEmpty = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                if isEffectivelyEmpty {
                    return Just(query)
                        .eraseToAnyPublisher()
                }

                return Just(query)
                    .delay(for: .milliseconds(80), scheduler: DispatchQueue.main)
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates()

        let settingsChanges = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .prepend(Notification(name: UserDefaults.didChangeNotification))
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)

        let dataChanges = Publishers.CombineLatest4($items, $selectedGroupId, $currentFilter, $selectedBuiltInGroup)

        Publishers.CombineLatest3(searchQueries, dataChanges, settingsChanges)
            .sink { [weak self] (query, quadruple, _) in
                guard let self else { return }
                let (allItems, groupId, filter, builtInGroup) = quadruple

                // activateDisplayedScope 已同步刷新时，跳过同一次 scope 回声。
                if self.suppressFilterPipelineEcho {
                    self.activeSearchQuery = query
                    return
                }

                // Background history pages already extend displayed IDs cheaply.
                // Skip full refilter on every page merge to keep scrolling smooth
                // (Paste-style: visible list stays stable while more data streams in).
                let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
                if self.isBulkHistoryLoading,
                   cleanQuery.isEmpty,
                   groupId == nil,
                   filter == nil,
                   builtInGroup == nil {
                    self.activeSearchQuery = query
                    return
                }

                self.activeSearchQuery = query

                // 搜索词变化：走 DB 分页，避免只在已加载窗口里搜。
                if cleanQuery != self.pagination.activeQuery {
                    if cleanQuery.isEmpty == false {
                        self.beginSearchPagination(query: cleanQuery)
                        return
                    }
                    if self.pagination.activeQuery.isEmpty == false {
                        self.loadData(mode: .visibleFirst)
                        return
                    }
                }

                self.performAsyncFilter(
                    query: query,
                    items: allItems,
                    groupId: groupId,
                    typeFilter: filter,
                    builtInGroup: builtInGroup
                )
            }
            .store(in: &cancellables)
    }

    func performAsyncFilter(
        query: String,
        items: [ClipboardItem],
        groupId: String?,
        typeFilter: ClipboardContentType?,
        builtInGroup: ClipboardBuiltInGroup?
    ) {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        filterGeneration &+= 1
        let thisGeneration = filterGeneration

        // 无搜索词的分组/类型过滤只是 O(n) 的轻量比较(几百条 <1ms),
        // 同步执行让标签高亮与卡片列表在同一帧切换;
        // 走后台双跳会插入至少两个 runloop 周期的空白帧,用户会看到"加载过程"。
        if cleanQuery.isEmpty {
            if groupId == nil && typeFilter == nil && builtInGroup == nil {
                // 「全部」：CoW 直通，禁止 map+全量 rematerialize
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    publishAllScopeDisplayedItems()
                    reconcileSelectionAfterDisplayedItemsChange()
                }
                publishSearchScrollResetIfNeeded(query: cleanQuery)
                return
            }

            let filteredIDs = items.compactMap { item -> UUID? in
                if let filter = typeFilter, item.contentType != filter {
                    return nil
                }
                if let gid = groupId, item.groupIDs.contains(gid) == false {
                    return nil
                }
                if let builtInGroup, builtInGroup.matches(item) == false {
                    return nil
                }
                return item.id
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                publishDisplayedItemIDs(filteredIDs)
                reconcileSelectionAfterDisplayedItemsChange()
            }
            publishSearchScrollResetIfNeeded(query: cleanQuery)
            return
        }

        // 文本搜索涉及 localizedStandardContains 等重操作,保持后台执行。
        DispatchQueue.global(qos: .userInitiated).async {
            let filteredIDs = items.compactMap { item -> UUID? in
                if let filter = typeFilter, item.contentType != filter {
                    return nil
                }

                if let gid = groupId, item.groupIDs.contains(gid) == false {
                    return nil
                }

                if let builtInGroup, builtInGroup.matches(item) == false {
                    return nil
                }

                // Prefer preview-sized fields on the hot path; rawText can be huge.
                let searchable = item.searchableText ?? item.textPreview
                let matchesText = searchable.range(of: cleanQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                let matchesApp = item.appName.range(of: cleanQuery, options: [.caseInsensitive]) != nil

                guard matchesText || matchesApp else {
                    return nil
                }

                return item.id
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.filterGeneration == thisGeneration else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    self.publishDisplayedItemIDs(filteredIDs)
                    self.reconcileSelectionAfterDisplayedItemsChange()
                }
                self.publishSearchScrollResetIfNeeded(query: cleanQuery)
            }
        }
    }

    private func publishSearchScrollResetIfNeeded(query: String) {
        guard query != lastSearchResultScrollQuery else { return }

        lastSearchResultScrollQuery = query
        searchResultScrollTargetID = displayedItemIDs.first
        searchResultScrollGeneration &+= 1
    }

    func loadData(mode: DataLoadMode = .fullRefresh) {
        dataLoadGeneration &+= 1
        let generation = dataLoadGeneration
        historyLoadTask?.cancel()
        isBulkHistoryLoading = false

        let pageSize = pagination.pageSize > 0 ? pagination.pageSize : Self.historyPageSize
        pagination = HistoryPaginationState(
            loadedCount: 0,
            pageSize: pageSize,
            hasMore: true,
            isLoading: true,
            generation: generation,
            activeQuery: "",
            scopeGroupId: nil,
            scopeTypeRawValue: nil,
            scopePinnedOnly: false
        )

        // 内存有前缀但当前 scope 仍空时也要亮 loading，避免空托盘闪一下
        if items.isEmpty || displayedItems.isEmpty {
            isInitialHistoryLoading = true
        }

        // 读路径的优先级反转由 StorageManager.detachedRead 统一兜底,
        // 这里保持普通 MainActor Task 即可。仅拉首屏，不再 while 扫全库。
        historyLoadTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let firstPage = await StorageManager.shared.fetchItemsPage(
                searchText: "",
                groupId: nil,
                typeRawValue: nil,
                fetchLimit: pageSize,
                offset: 0
            )

            guard !Task.isCancelled, generation == self.dataLoadGeneration else { return }
            self.cacheScopePage(
                firstPage,
                for: .all(query: ""),
                loadedCount: firstPage.count,
                hasMore: firstPage.count == pageSize
            )

            self.applyInitialHistoryPage(
                firstPage,
                generation: generation,
                mode: mode
            )
            self.syncPaginationAfterPage(
                loadedCount: firstPage.count,
                pageReceivedCount: firstPage.count,
                pageSize: pageSize,
                generation: generation
            )
        }
    }

    /// 列表尾部可见时触发续页。由卡片 `onAppear` 调用。
    @MainActor
    func loadMoreIfNeeded(currentItemID: UUID) {
        guard HistoryPaginationPolicy.shouldLoadMore(
            currentID: currentItemID,
            displayedIDs: displayedItemIDs,
            state: pagination,
            prefetchDistance: Self.loadMorePrefetchDistance
        ) else { return }

        let generation = dataLoadGeneration
        guard generation == pagination.generation else { return }

        let pageSize = pagination.pageSize > 0 ? pagination.pageSize : Self.historyPageSize
        let offset = pagination.loadedCount
        let query = pagination.activeQuery
        let groupId = pagination.scopeGroupId
        let typeRaw = pagination.scopeTypeRawValue
        let pinnedOnly = pagination.scopePinnedOnly

        pagination.isLoading = true
        isLoadingMoreHistory = true

        historyLoadTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let page = await StorageManager.shared.fetchItemsPage(
                searchText: query,
                groupId: groupId,
                typeRawValue: typeRaw,
                pinnedOnly: pinnedOnly,
                fetchLimit: pageSize,
                offset: offset
            )

            guard !Task.isCancelled, generation == self.dataLoadGeneration else { return }

            let newLoaded = offset + page.count
            self.appendHistoryPage(page, generation: generation, loadedCount: newLoaded)
            self.syncPaginationAfterPage(
                loadedCount: newLoaded,
                pageReceivedCount: page.count,
                pageSize: pageSize,
                generation: generation
            )
        }
    }

    /// 用 DB 搜索首屏替换展示列表（不依赖内存已加载窗口）。
    @MainActor
    func beginSearchPagination(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }

        activeScopeCacheKey = scopeCacheKey(
            query: trimmed,
            groupID: selectedGroupId,
            type: currentFilter,
            builtInGroup: selectedBuiltInGroup
        )

        // 保留当前分组/类型 scope，搜索在 scope 内进行。
        beginPagedFetch(
            query: trimmed,
            groupId: selectedGroupId,
            typeRawValue: currentFilter?.rawValue,
            pinnedOnly: selectedBuiltInGroup == .favorites,
            replaceDisplayedWithPage: true
        )
    }

    /// 切换用户分组 / 类型 / 收藏 时的 DB 首屏。
    @MainActor
    func beginScopePagination(groupId: String?, typeRawValue: String?, pinnedOnly: Bool = false) {
        beginPagedFetch(
            query: activeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines),
            groupId: groupId,
            typeRawValue: typeRawValue,
            pinnedOnly: pinnedOnly,
            replaceDisplayedWithPage: true
        )
    }

    @MainActor
    private func beginPagedFetch(
        query: String,
        groupId: String?,
        typeRawValue: String?,
        pinnedOnly: Bool,
        replaceDisplayedWithPage: Bool
    ) {
        dataLoadGeneration &+= 1
        let generation = dataLoadGeneration
        historyLoadTask?.cancel()
        isBulkHistoryLoading = false

        let pageSize = pagination.pageSize > 0 ? pagination.pageSize : Self.historyPageSize
        pagination = HistoryPaginationState(
            loadedCount: 0,
            pageSize: pageSize,
            hasMore: true,
            isLoading: true,
            generation: generation,
            activeQuery: query,
            scopeGroupId: groupId,
            scopeTypeRawValue: typeRawValue,
            scopePinnedOnly: pinnedOnly
        )
        activeScopeCacheKey = scopeCacheKey(
            query: query,
            groupID: groupId,
            type: typeRawValue.flatMap(ClipboardContentType.init(rawValue:)),
            builtInGroup: pinnedOnly ? .favorites : nil
        )
        isLoadingMoreHistory = true
        if items.isEmpty || displayedItems.isEmpty {
            isInitialHistoryLoading = true
        }

        historyLoadTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let page = await StorageManager.shared.fetchItemsPage(
                searchText: query,
                groupId: groupId,
                typeRawValue: typeRawValue,
                pinnedOnly: pinnedOnly,
                fetchLimit: pageSize,
                offset: 0
            )

            guard !Task.isCancelled, generation == self.dataLoadGeneration else { return }

            let requestKey = self.scopeCacheKey(
                query: query,
                groupID: groupId,
                type: typeRawValue.flatMap(ClipboardContentType.init(rawValue:)),
                builtInGroup: pinnedOnly ? .favorites : nil
            )
            self.cacheScopePage(
                page,
                for: requestKey,
                loadedCount: page.count,
                hasMore: page.count == pageSize
            )
            guard self.activeScopeCacheKey == requestKey else { return }

            if replaceDisplayedWithPage {
                self.mergeItems(page, prepend: true, enqueueLinkMetadata: false)
                var transaction = Transaction()
                transaction.disablesAnimations = true
                transaction.animation = nil
                withTransaction(transaction) {
                    self.publishDisplayedItemIDs(page.map(\.id))
                    self.reconcileSelectionAfterDisplayedItemsChange()
                }
                if query.isEmpty == false {
                    self.publishSearchScrollResetIfNeeded(query: query)
                }
            } else {
                self.applyInitialHistoryPage(page, generation: generation, mode: .visibleFirst)
            }
            self.syncPaginationAfterPage(
                loadedCount: page.count,
                pageReceivedCount: page.count,
                pageSize: pageSize,
                generation: generation
            )
        }
    }

    /// 用本页实际条数更新 hasMore / 完成态。
    @MainActor
    private func syncPaginationAfterPage(
        loadedCount: Int,
        pageReceivedCount: Int,
        pageSize: Int,
        generation: UInt
    ) {
        guard generation == dataLoadGeneration else { return }

        pagination.loadedCount = loadedCount
        pagination.hasMore = pageReceivedCount == pageSize && pageReceivedCount > 0
        pagination.isLoading = false
        isLoadingMoreHistory = false
        isInitialHistoryLoading = false
        isBulkHistoryLoading = false
        loadedHistoryCount = items.count
        hasLoadedFullHistory = pagination.hasMore == false

        if hasLoadedFullHistory {
            finishHistoryLoadingIfCurrent(generation: generation, loadedCount: loadedCount)
        }
    }

    func applyLoadedItems(_ mappedItems: [ClipboardItem]) {
        replaceItems(mappedItems)
        isInitialHistoryLoading = false

        let validIDs = Set(mappedItems.map(\.id))
        let staleIDs = selectedItemIDs.subtracting(validIDs)
        if !staleIDs.isEmpty {
            selectedItemIDs.subtract(staleIDs)
        }
        if let anchor = lastSelectedID, !validIDs.contains(anchor) {
            lastSelectedID = nil
        }

        // 不依赖 filter pipeline（分组切换时 suppressFilterPipelineEcho 会吞掉 $items 回声）。
        // 「全部」必须直接按最新 items 发布，否则会残留上一分组的 displayedItemIDs。
        let query = activeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty,
           selectedGroupId == nil,
           currentFilter == nil,
           selectedBuiltInGroup == nil {
            publishAllScopeDisplayedItems()
        } else {
            refreshDisplayedItemsFromCurrentScope()
        }
        reconcileSelectionAfterDisplayedItemsChange()
    }

    @MainActor
    func applyInitialHistoryPage(_ pageItems: [ClipboardItem], generation: UInt, mode: DataLoadMode) {
        guard generation == dataLoadGeneration else { return }

        // 切换 scope 时已经在 activateDisplayedScope 中 bump 过一次身份。
        // DB 校正只更新 IDs，避免第二次重建 LazyHStack。
        if suppressListAnimations == false {
            noteListContentReplacedWithoutAnimation()
        }

        let query = activeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAllScope =
            query.isEmpty
            && selectedGroupId == nil
            && currentFilter == nil
            && selectedBuiltInGroup == nil

        if mode == .visibleFirst, items.isEmpty == false, isAllScope == false {
            // 非「全部」的 visibleFirst 合并（例如面板重开）
            let preexisting = items
            mergeItems(pageItems, prepend: true)

            let pageNewestTimestamp = pageItems.map(\.timestamp).max() ?? .distantPast
            for candidate in preexisting where candidate.timestamp > pageNewestTimestamp {
                upsertItem(candidate, shouldResort: true)
            }
            resortItemsForPresentation()
            refreshDisplayedItemsFromCurrentScope()
            reconcileSelectionAfterDisplayedItemsChange()
        } else if mode == .visibleFirst, items.isEmpty == false, isAllScope {
            // 「全部」+ visibleFirst：合并后必须按时间重排并发布全 scope，不能沿用旧 displayed IDs。
            let preexisting = items
            mergeItems(pageItems, prepend: true)
            let pageNewestTimestamp = pageItems.map(\.timestamp).max() ?? .distantPast
            for candidate in preexisting where candidate.timestamp > pageNewestTimestamp {
                upsertItem(candidate, shouldResort: true)
            }
            resortItemsForPresentation()
            publishAllScopeDisplayedItems()
            reconcileSelectionAfterDisplayedItemsChange()
        } else {
            // fullRefresh 或空内存：用 DB 最新页整体替换
            applyLoadedItems(pageItems)
        }

        isInitialHistoryLoading = false
        isLoadingMoreHistory = false
        loadedHistoryCount = items.count
        // hasLoadedFullHistory / pagination 由 syncPaginationAfterPage 统一写入
    }

    @MainActor
    func appendHistoryPage(_ pageItems: [ClipboardItem], generation: UInt, loadedCount: Int) {
        guard generation == dataLoadGeneration else { return }
        guard pageItems.isEmpty == false else {
            loadedHistoryCount = loadedCount
            return
        }

        // Skip link-metadata thrash during bulk stream; first visible page already enqueued.
        mergeItems(pageItems, prepend: false, enqueueLinkMetadata: false)

        let hasActiveScope =
            activeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || selectedGroupId != nil
            || currentFilter != nil
            || selectedBuiltInGroup != nil

        if hasActiveScope {
            refreshDisplayedItemsFromCurrentScope()
        } else {
            // Unfiltered history: append IDs only — no O(n) re-scope of the whole list.
            var nextIDs = displayedItemIDs
            nextIDs.reserveCapacity(nextIDs.count + pageItems.count)
            let existing = Set(nextIDs)
            for item in pageItems where existing.contains(item.id) == false {
                nextIDs.append(item.id)
            }
            publishDisplayedItemIDs(nextIDs)
        }

        isInitialHistoryLoading = false
        loadedHistoryCount = loadedCount
        trimItemsToSoftCapIfNeeded()
    }

    @MainActor
    func finishHistoryLoadingIfCurrent(generation: UInt, loadedCount: Int) {
        guard generation == dataLoadGeneration else { return }
        isBulkHistoryLoading = false
        isInitialHistoryLoading = false
        isLoadingMoreHistory = false
        loadedHistoryCount = loadedCount
        hasLoadedFullHistory = true
        pagination.hasMore = false
        pagination.isLoading = false
        pagination.loadedCount = loadedCount

        // One final scope sync in case filters changed mid-load.
        if activeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || selectedGroupId != nil
            || currentFilter != nil
            || selectedBuiltInGroup != nil {
            refreshDisplayedItemsFromCurrentScope()
        } else {
            rematerializeDisplayedItems()
        }
    }
}
