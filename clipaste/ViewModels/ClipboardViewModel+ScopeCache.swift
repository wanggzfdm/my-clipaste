import Foundation

extension ClipboardViewModel {
    func scopeCacheKey(
        query: String,
        groupID: String?,
        type: ClipboardContentType?,
        builtInGroup: ClipboardBuiltInGroup?
    ) -> ClipboardScopeKey {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if builtInGroup == .favorites {
            return .pinned(query: normalizedQuery)
        }
        if let groupID {
            return .group(query: normalizedQuery, id: groupID)
        }
        if let type {
            return .type(query: normalizedQuery, rawValue: type.rawValue)
        }
        return .all(query: normalizedQuery)
    }

    func currentScopeCacheKey() -> ClipboardScopeKey {
        scopeCacheKey(
            query: activeSearchQuery,
            groupID: selectedGroupId,
            type: currentFilter,
            builtInGroup: selectedBuiltInGroup
        )
    }

    @discardableResult
    func restoreCachedScopeIfAvailable() -> Bool {
        let key = activeScopeCacheKey ?? currentScopeCacheKey()
        guard let snapshot = scopeCache.snapshot(for: key) else { return false }

        let missingItems = snapshot.items.filter { item(for: $0.id) == nil }
        mergeItems(missingItems, prepend: true, enqueueLinkMetadata: false)
        let availableIDs = Set(items.map(\.id))
        let cachedIDs = snapshot.itemIDs.filter { availableIDs.contains($0) }
        guard cachedIDs.isEmpty == false else { return false }

        publishDisplayedItemIDs(cachedIDs)
        isInitialHistoryLoading = false
        isLoadingMoreHistory = true
        reconcileSelectionAfterDisplayedItemsChange()
        return true
    }

    func cacheScopePage(
        _ page: [ClipboardItem],
        for key: ClipboardScopeKey,
        loadedCount: Int,
        hasMore: Bool
    ) {
        guard page.isEmpty == false else { return }

        scopeCache.insert(
            ClipboardScopeSnapshot(
                items: page,
                itemIDs: page.map(\.id),
                loadedCount: loadedCount,
                hasMore: hasMore,
                updatedAt: Date()
            ),
            for: key
        )
    }

    func invalidateScopeCache(forGroupID groupID: String) {
        scopeCache.remove { key in
            if case let .group(_, cachedGroupID) = key {
                return cachedGroupID == groupID
            }
            return false
        }
    }

    func keepOnlyAllScopeCache() {
        scopeCache.removeAll { key in
            if case .all = key { return true }
            return false
        }
    }

    func shouldApplyScopeResult(
        resultGeneration: UInt,
        currentGeneration: UInt,
        resultKey: ClipboardScopeKey,
        currentKey: ClipboardScopeKey
    ) -> Bool {
        resultGeneration == currentGeneration && resultKey == currentKey
    }
}
