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
        shouldResetSelectionToFirstDisplayedItem = true
        loadData(mode: .fullRefresh)
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
        preparePanelDataIfNeeded()
        if items.isEmpty {
            hydrateFromWarmCacheIfAvailable()
        }
    }

    /// Background reconcile after the panel is already visible.
    /// Avoids blocking `makeKeyAndOrderFront` on pasteboard capture or DB reads.
    func refreshHistoryAfterPresentationIfNeeded() async {
        if needsReloadOnNextPresentation {
            needsReloadOnNextPresentation = false
            shouldResetSelectionToFirstDisplayedItem = true
            loadData(mode: .fullRefresh)
            loadCustomGroups()
            return
        }

        if items.isEmpty {
            await refreshFirstHistoryPageForPresentation()
        }
    }

    func refreshFirstHistoryPageForPresentation() async {
        preparePanelDataIfNeeded()

        dataLoadGeneration &+= 1
        let generation = dataLoadGeneration
        historyLoadTask?.cancel()

        let firstPage = await StorageManager.shared.fetchItemsPage(
            searchText: "",
            fetchLimit: Self.initialVisibleItemBatchSize,
            offset: 0
        )

        applyInitialHistoryPage(
            firstPage,
            generation: generation,
            mode: .visibleFirst
        )
    }

    func endPresentation() {
        isPanelPresentationActive = false
        dismissAutoPreviewIfNeeded()
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
                self.loadData(mode: .fullRefresh)
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
        guard searchInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              activeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              currentFilter == nil,
              selectedBuiltInGroup == nil,
              selectedGroupId == nil else {
            return
        }

        let routeKey = ClipboardRuntimeStore.shared.rootIdentity
        guard let cachedItems = ClipboardHistoryWarmCache.shared.snapshot(for: routeKey) else {
            return
        }

        if items.isEmpty || hasPreparedPanelData == false {
            applyLoadedItems(cachedItems)
            loadedHistoryCount = cachedItems.count
            hasLoadedFullHistory = cachedItems.count < ClipboardHistoryWarmCache.defaultLimit
            return
        }

        // Keep an already-loaded list, but merge a fresher warm-cache head
        // (optimistic capture while the panel was idle / not yet prepared).
        guard let cachedFirst = cachedItems.first else { return }
        if items.first?.contentHash != cachedFirst.contentHash {
            applyOptimisticCapture(cachedFirst, silent: true)
        }
    }
}
