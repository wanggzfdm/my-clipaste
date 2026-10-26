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
            hasPreparedPanelData = true
            hydrateFromWarmCacheIfAvailable()
            shouldResetSelectionToFirstDisplayedItem = true
            shouldAutoSelectFirstItemAfterNextRefresh = settingsViewModel.autoFocusFirstItemOnPanelActivation
            loadData(mode: .visibleFirst)
            loadCustomGroups()
            return
        }

        guard needsReloadOnNextPresentation else { return }
        needsReloadOnNextPresentation = false
        shouldResetSelectionToFirstDisplayedItem = true
        shouldAutoSelectFirstItemAfterNextRefresh = settingsViewModel.autoFocusFirstItemOnPanelActivation
        loadData(mode: .fullRefresh)
        loadCustomGroups()
    }

    func endPresentation() {
        isPanelPresentationActive = false
        shouldAutoSelectFirstItemAfterNextRefresh = false
        dismissAutoPreviewIfNeeded()
        historyLoadTask?.cancel()
        historyLoadTask = nil

        let presentationWarmItems = Array(items.prefix(ClipboardHistoryWarmCache.defaultLimit))
        Task { @MainActor in
            await ListRenderEngine.shared.prewarmTextPreviews(for: presentationWarmItems)
        }

        for item in presentationWarmItems where item.contentType == .image {
            ClipboardImagePipeline.shared.prewarmThumbnail(for: item.id, maxPixelSize: 320)
        }
        // Retain the bounded first page and its rendered-text cache across normal hides.
        // Clipboard changes mark needsReloadOnNextPresentation and still trigger a refresh.
        needsReloadOnNextPresentation = false
    }

    func refreshDataWhilePanelHidden() {
        guard isPanelPresentationActive == false else { return }

        backgroundHistoryRefreshGeneration &+= 1
        let generation = backgroundHistoryRefreshGeneration
        backgroundHistoryRefreshTask?.cancel()
        backgroundHistoryRefreshTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let refreshedItems = await StorageManager.shared.fetchItemsPage(
                searchText: "",
                fetchLimit: Self.backgroundLoadMaxItems,
                offset: 0
            )
            guard !Task.isCancelled,
                  self.isPanelPresentationActive == false,
                  self.backgroundHistoryRefreshGeneration == generation else {
                return
            }

            self.applyLoadedItems(refreshedItems)
            self.loadedHistoryCount = refreshedItems.count
            self.hasLoadedFullHistory = ClipboardHistoryPagingState.isComplete(
                count: refreshedItems.count,
                limit: Self.backgroundLoadMaxItems
            )
            self.loadCustomGroups()
            self.needsReloadOnNextPresentation = false
            self.backgroundHistoryRefreshTask = nil
        }
    }

    func setupDataSubscriptions() {
        NotificationCenter.default.publisher(for: .clipboardDataDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.hasPreparedPanelData else { return }
                guard self.isPanelPresentationActive else {
                    self.needsReloadOnNextPresentation = true
                    self.refreshDataWhilePanelHidden()
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let cachedItems = await ClipboardHistoryWarmCache.shared.snapshot(for: routeKey) else { return }
            guard self.items.isEmpty || self.hasPreparedPanelData == false else { return }
            self.applyLoadedItems(cachedItems)
            self.loadedHistoryCount = cachedItems.count
            self.hasLoadedFullHistory = ClipboardHistoryPagingState.isComplete(
                count: cachedItems.count,
                limit: ClipboardHistoryWarmCache.defaultLimit
            )
            // hydrate 完成后清空 warm cache，释放重复持有的 ClipboardItem 内存
            await ClipboardHistoryWarmCache.shared.clear()
        }
    }
}
