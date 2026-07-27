import AppKit
import SwiftUI

extension ClipboardViewModel {
    func item(for id: UUID) -> ClipboardItem? {
        guard let index = itemIndexByID[id], items.indices.contains(index) else {
            return nil
        }

        return items[index]
    }

    func publishDisplayedItemIDs(_ ids: [UUID]) {
        // 与当前 IDs 完全一致则跳过（避免切回「全部」时无意义的二次发布）
        if ids.count == displayedItemIDs.count,
           ids.isEmpty || (ids.first == displayedItemIDs.first && ids.last == displayedItemIDs.last),
           zip(ids, displayedItemIDs).allSatisfy({ $0 == $1 }) {
            // IDs 没变，但 items 内容可能变了：尝试 CoW / 轻量刷新
            rematerializeDisplayedItems()
            return
        }
        displayedItemIDs = ids
        rematerializeDisplayedItems()
    }

    /// 将 displayedItemIDs 物化为 displayedItems。
    /// 「全部」且 ID 与 items 同序时走 Array CoW（O(1)），绝不 compactMap 拷贝 NSImage。
    func rematerializeDisplayedItems() {
        displayMaterializeTask?.cancel()
        displayMaterializeGeneration &+= 1
        let generation = displayMaterializeGeneration
        let ids = displayedItemIDs

        // —— 快路径 1：全部 scope，ID 与 items 一一对应 → CoW 共享底层 buffer
        if isAllScopeIdentity(ids) {
            // Array CoW：赋值几乎免费，直到某一方 mutate 才复制
            if !isDisplayedItemsCoWAligned(with: items) {
                displayedItems = items
            }
            return
        }

        // —— 快路径 2：已物化且 ID 序列一致 → 不整表重建（避免 NSImage Hashable 比较）
        if ids.count == displayedItems.count,
           zip(ids, displayedItems).allSatisfy({ $0.0 == $0.1.id }) {
            return
        }

        let windowSize = Self.displayMaterializeWindowSize

        // 小列表：一次物化
        if ids.count <= windowSize {
            let materialised = materializeItems(for: ids)
            displayedItems = materialised
            return
        }

        // 大过滤列表：只物化首窗，不再分帧追加整表。
        // 滚动/键盘用 displayedItemIDs + item(for:)；视图层 ForEach 也走 ID。
        // 分帧追加曾导致「全部」切换后持续卡顿（每次 @Published 大数组赋值）。
        let firstWindow = materializeItems(for: ids.prefix(windowSize))
        displayedItems = firstWindow
        _ = generation // 保留 generation 语义，取消旧 task 即可
    }

    /// 「全部」专用：直接共享 items，避免 map+compactMap。
    func publishAllScopeDisplayedItems() {
        displayMaterializeTask?.cancel()
        displayMaterializeGeneration &+= 1

        let ids: [UUID]
        // 若 displayedItemIDs 已是 items 的完整 ID 序列，复用，省一次 map
        if isAllScopeIdentity(displayedItemIDs), displayedItemIDs.count == items.count {
            ids = displayedItemIDs
        } else {
            ids = items.map(\.id)
        }

        displayedItemIDs = ids
        // CoW O(1)
        if !isDisplayedItemsCoWAligned(with: items) {
            displayedItems = items
        }
    }

    private func materializeItems<S: Sequence>(for idSequence: S) -> [ClipboardItem] where S.Element == UUID {
        idSequence.compactMap { id -> ClipboardItem? in
            guard let index = itemIndexByID[id], items.indices.contains(index) else {
                return nil
            }
            return items[index]
        }
    }

    /// displayedItemIDs 是否表示「未过滤的全部 items」同序视图。
    private func isAllScopeIdentity(_ ids: [UUID]) -> Bool {
        guard ids.count == items.count, !items.isEmpty else {
            return ids.isEmpty && items.isEmpty
        }
        // 抽样 + 两端，避免每次 zip 全表（仍正确的概率极高；全表 UUID 对比在 1 万级也可接受）
        if ids.first != items.first?.id || ids.last != items.last?.id {
            return false
        }
        // 完整校验：UUID 对比很便宜，远低于拷贝 ClipboardItem
        return zip(ids, items).allSatisfy { $0.0 == $0.1.id }
    }

    /// 粗判 displayedItems 是否已与 items CoW 对齐（同长度、同首尾 id）。
    private func isDisplayedItemsCoWAligned(with source: [ClipboardItem]) -> Bool {
        displayedItems.count == source.count
            && displayedItems.first?.id == source.first?.id
            && displayedItems.last?.id == source.last?.id
    }

    @discardableResult
    func updateItem(id: UUID, _ mutate: (inout ClipboardItem) -> Void) -> Bool {
        guard let index = itemIndexByID[id], items.indices.contains(index) else {
            return false
        }

        mutate(&items[index])
        refreshDisplayedItemsFromCurrentScope()
        return true
    }

    func replaceItems(_ newItems: [ClipboardItem], enqueueLinkMetadata: Bool = true) {
        items = newItems
        rebuildItemIndexes()
        if enqueueLinkMetadata, isBulkHistoryLoading == false {
            enqueueMissingLinkMetadata(for: newItems)
        }
    }

    func mergeItems(_ incomingItems: [ClipboardItem], prepend: Bool, enqueueLinkMetadata: Bool = true) {
        guard !incomingItems.isEmpty else { return }

        let combined = prepend ? (incomingItems + items) : (items + incomingItems)
        let deduplicated = deduplicatedItemsPreservingOrder(combined)
        items = deduplicated
        rebuildItemIndexes()
        if enqueueLinkMetadata, isBulkHistoryLoading == false {
            enqueueMissingLinkMetadata(for: incomingItems)
        }
    }

    func removeItems(withIDs ids: Set<UUID>) {
        guard !ids.isEmpty else { return }

        items.removeAll { ids.contains($0.id) }
        rebuildItemIndexes()
        pagination.loadedCount = items.count
        if items.isEmpty {
            pagination.hasMore = false
            hasLoadedFullHistory = true
        }
        loadedHistoryCount = items.count
        refreshDisplayedItemsFromCurrentScope()
    }

    func removeItem(withHash contentHash: String) {
        guard let index = itemIndexByHash[contentHash], items.indices.contains(index) else {
            return
        }

        items.remove(at: index)
        rebuildItemIndexes()
        pagination.loadedCount = items.count
        if items.isEmpty {
            pagination.hasMore = false
            hasLoadedFullHistory = true
        }
        loadedHistoryCount = items.count
        refreshDisplayedItemsFromCurrentScope()
    }

    func moveItem(withID id: UUID, to destinationIndex: Int) {
        guard let sourceIndex = itemIndexByID[id], items.indices.contains(sourceIndex) else {
            return
        }

        let boundedDestination = min(max(destinationIndex, 0), items.count - 1)
        guard sourceIndex != boundedDestination else { return }

        let movedItem = items.remove(at: sourceIndex)
        items.insert(movedItem, at: boundedDestination)
        rebuildItemIndexes()
        refreshDisplayedItemsFromCurrentScope()
    }

    func upsertItem(_ item: ClipboardItem, shouldResort: Bool) {
        if let index = itemIndexByHash[item.contentHash], items.indices.contains(index) {
            items[index] = item
        } else {
            items.insert(item, at: 0)
        }

        if shouldResort {
            sortItemsByPresentationOrder()
        }

        rebuildItemIndexes()
        refreshDisplayedItemsFromCurrentScope()
        enqueueMissingLinkMetadata(for: [item])
    }

    /// Memory-first capture: push a lightweight item into the list before DB persistence completes.
    func applyOptimisticCapture(_ item: ClipboardItem, silent: Bool, selectIfSilentOpen: Bool = false) {
        let apply = {
            self.upsertItem(item, shouldResort: true)
            if selectIfSilentOpen {
                self.selectFirstDisplayedItem(animatedScroll: false)
            }
        }

        if silent || isSilentPresentationMutation {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, apply)
        } else {
            apply()
        }
    }

    func beginSilentPresentationMutations() {
        silentPresentationEndTask?.cancel()
        silentPresentationEndTask = nil
        isSilentPresentationMutation = true
    }

    func endSilentPresentationMutations(after delay: Duration = .milliseconds(120)) {
        silentPresentationEndTask?.cancel()
        silentPresentationEndTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, Task.isCancelled == false else { return }
            self.isSilentPresentationMutation = false
            self.silentPresentationEndTask = nil
        }
    }

    func performSilentListMutation(_ body: () -> Void) {
        if isSilentPresentationMutation {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, body)
        } else {
            body()
        }
    }

    /// Resort after merges that may demote in-memory optimistic items.
    func resortItemsForPresentation() {
        sortItemsByPresentationOrder()
        rebuildItemIndexes()
        refreshDisplayedItemsFromCurrentScope()
    }
}

extension ClipboardViewModel {
    func refreshDisplayedItemsFromCurrentScope() {
        let query = activeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        // 「全部」且无搜索：CoW 直通，这是切到全部卡顿的主修复
        if query.isEmpty,
           currentFilter == nil,
           selectedBuiltInGroup == nil,
           selectedGroupId == nil {
            publishAllScopeDisplayedItems()
            return
        }

        let ids = items.compactMap { item -> UUID? in
            guard matchesCurrentDisplayScope(item, query: query) else {
                return nil
            }
            return item.id
        }
        publishDisplayedItemIDs(ids)
    }
}

extension ClipboardViewModel {
    func rebuildItemIndexes() {
        var idIndex: [UUID: Int] = [:]
        var hashIndex: [String: Int] = [:]
        idIndex.reserveCapacity(items.count)
        hashIndex.reserveCapacity(items.count)

        for (offset, item) in items.enumerated() {
            idIndex[item.id] = offset
            hashIndex[item.contentHash] = offset
        }

        itemIndexByID = idIndex
        itemIndexByHash = hashIndex
    }

    func sortItemsByPresentationOrder() {
        items.sort { lhs, rhs in
            lhs.timestamp > rhs.timestamp
        }
    }

    func matchesCurrentDisplayScope(_ item: ClipboardItem, query: String) -> Bool {
        if let currentFilter, item.contentType != currentFilter {
            return false
        }

        if let selectedBuiltInGroup, selectedBuiltInGroup.matches(item) == false {
            return false
        }

        if let selectedGroupId, item.groupIDs.contains(selectedGroupId) == false {
            return false
        }

        guard !query.isEmpty else {
            return true
        }

        let searchable = item.searchableText ?? item.textPreview
        if searchable.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            return true
        }

        return item.appName.range(of: query, options: [.caseInsensitive]) != nil
    }

    func deduplicatedItemsPreservingOrder(_ sourceItems: [ClipboardItem]) -> [ClipboardItem] {
        var seenIDs: Set<UUID> = []
        var seenHashes: Set<String> = []
        var result: [ClipboardItem] = []
        result.reserveCapacity(sourceItems.count)

        for item in sourceItems {
            guard seenIDs.insert(item.id).inserted else { continue }
            guard seenHashes.insert(item.contentHash).inserted else { continue }
            result.append(item)
        }

        return result
    }

    func enqueueMissingLinkMetadata(for sourceItems: [ClipboardItem]) {
        // In plain (Default) mode neither titles nor icons are shown,
        // so there is no point making background network requests.
        guard settingsViewModel.linkDisplayMode == .rich else { return }

        let candidates = sourceItems
            .lazy
            .filter { $0.isFastLink && ($0.linkTitle == nil || $0.hasLinkIcon == false) }
            .prefix(24)

        for item in candidates {
            guard pendingLinkMetadataHashes.contains(item.contentHash) == false else { continue }

            let urlText = (item.rawText ?? item.previewText ?? item.textPreview)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard urlText.isEmpty == false else { continue }

            pendingLinkMetadataHashes.insert(item.contentHash)
            StorageManager.shared.processLinkMetadata(hash: item.contentHash, urlString: urlText)
        }
    }
}
