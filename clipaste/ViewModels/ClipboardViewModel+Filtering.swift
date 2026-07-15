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

        if cleanQuery.isEmpty && groupId == nil && typeFilter == nil && builtInGroup == nil {
            self.publishDisplayedItemIDs(items.map(\.id))
            reconcileSelectionAfterDisplayedItemsChange()
            return
        }

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

                if !cleanQuery.isEmpty {
                    // Prefer preview-sized fields on the hot path; rawText can be huge.
                    let searchable = item.searchableText ?? item.textPreview
                    let matchesText = searchable.range(of: cleanQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    let matchesApp = item.appName.range(of: cleanQuery, options: [.caseInsensitive]) != nil

                    guard matchesText || matchesApp else {
                        return nil
                    }
                }

                return item.id
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.filterGeneration == thisGeneration else { return }
                self.publishDisplayedItemIDs(filteredIDs)
                self.reconcileSelectionAfterDisplayedItemsChange()
            }
        }
    }

    func loadData(mode: DataLoadMode = .fullRefresh) {
        dataLoadGeneration &+= 1
        let generation = dataLoadGeneration
        historyLoadTask?.cancel()
        isBulkHistoryLoading = false

        if items.isEmpty {
            isInitialHistoryLoading = true
        }

        // 读路径的优先级反转由 StorageManager.detachedRead 统一兜底,
        // 这里保持普通 MainActor Task 即可。
        historyLoadTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let firstPage = await StorageManager.shared.fetchItemsPage(
                searchText: "",
                fetchLimit: Self.initialVisibleItemBatchSize,
                offset: 0
            )

            guard !Task.isCancelled else { return }
            self.applyInitialHistoryPage(
                firstPage,
                generation: generation,
                mode: mode
            )

            guard firstPage.count == Self.initialVisibleItemBatchSize else {
                self.finishHistoryLoadingIfCurrent(generation: generation, loadedCount: firstPage.count)
                return
            }

            // Background pages: coalesce UI commits so scrolling is not interrupted
            // by a full list rebuild every 160 rows (Paste-style streaming).
            self.isBulkHistoryLoading = true
            var offset = firstPage.count
            var totalLoaded = firstPage.count
            var pendingBackgroundItems: [ClipboardItem] = []
            pendingBackgroundItems.reserveCapacity(Self.backgroundPageBatchSize * 2)
            let coalesceTarget = Self.backgroundPageBatchSize * 2

            while !Task.isCancelled {
                let page = await StorageManager.shared.fetchItemsPage(
                    searchText: "",
                    fetchLimit: Self.backgroundPageBatchSize,
                    offset: offset
                )

                guard !Task.isCancelled else {
                    self.isBulkHistoryLoading = false
                    return
                }

                if page.isEmpty {
                    if !pendingBackgroundItems.isEmpty {
                        self.appendHistoryPage(
                            pendingBackgroundItems,
                            generation: generation,
                            loadedCount: totalLoaded
                        )
                        pendingBackgroundItems.removeAll(keepingCapacity: true)
                    }
                    self.finishHistoryLoadingIfCurrent(generation: generation, loadedCount: totalLoaded)
                    return
                }

                totalLoaded += page.count
                offset += page.count
                pendingBackgroundItems.append(contentsOf: page)

                let shouldFlush =
                    pendingBackgroundItems.count >= coalesceTarget
                    || page.count < Self.backgroundPageBatchSize

                if shouldFlush {
                    self.appendHistoryPage(
                        pendingBackgroundItems,
                        generation: generation,
                        loadedCount: totalLoaded
                    )
                    pendingBackgroundItems.removeAll(keepingCapacity: true)

                    // Yield a frame so Lazy* stacks can keep scrolling fluid.
                    try? await Task.sleep(nanoseconds: 8_000_000)
                }

                if page.count < Self.backgroundPageBatchSize {
                    self.finishHistoryLoadingIfCurrent(generation: generation, loadedCount: totalLoaded)
                    return
                }
            }

            self.isBulkHistoryLoading = false
        }
    }

    func applyLoadedItems(_ mappedItems: [ClipboardItem]) {
        replaceItems(mappedItems)
        isInitialHistoryLoading = false

        // Always use the filter pipeline to set displayedItemIDs to ensure
        // consistent behavior. The filter pipeline will set displayedItemIDs
        // based on the current activeSearchQuery (which may be debounced).
        // This ensures search state is preserved when loading new items.

        let validIDs = Set(mappedItems.map(\.id))
        let staleIDs = selectedItemIDs.subtracting(validIDs)
        if !staleIDs.isEmpty {
            selectedItemIDs.subtract(staleIDs)
        }
        if let anchor = lastSelectedID, !validIDs.contains(anchor) {
            lastSelectedID = nil
        }

        reconcileSelectionAfterDisplayedItemsChange()
    }

    @MainActor
    func applyInitialHistoryPage(_ pageItems: [ClipboardItem], generation: UInt, mode: DataLoadMode) {
        guard generation == dataLoadGeneration else { return }

        if mode == .visibleFirst, items.isEmpty == false {
            mergeItems(pageItems, prepend: true)
            refreshDisplayedItemsFromCurrentScope()
            reconcileSelectionAfterDisplayedItemsChange()
        } else {
            applyLoadedItems(pageItems)
        }

        isInitialHistoryLoading = false
        isLoadingMoreHistory = pageItems.count == Self.initialVisibleItemBatchSize
        loadedHistoryCount = items.count
        hasLoadedFullHistory = pageItems.count < Self.initialVisibleItemBatchSize
    }

    @MainActor
    func appendHistoryPage(_ pageItems: [ClipboardItem], generation: UInt, loadedCount: Int) {
        guard generation == dataLoadGeneration else { return }

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
        isLoadingMoreHistory = true
        loadedHistoryCount = loadedCount
    }

    @MainActor
    func finishHistoryLoadingIfCurrent(generation: UInt, loadedCount: Int) {
        guard generation == dataLoadGeneration else { return }
        isBulkHistoryLoading = false
        isInitialHistoryLoading = false
        isLoadingMoreHistory = false
        loadedHistoryCount = loadedCount
        hasLoadedFullHistory = true

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
