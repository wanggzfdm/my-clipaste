import AppKit
import Combine
import SwiftUI

extension ClipboardViewModel {
    func setupRecordChangeSubscriptions() {
        NotificationCenter.default.publisher(for: .clipboardRecordDidChange)
            .compactMap(\.clipboardRecordChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self else { return }

                if self.hasPreparedPanelData == false {
                    Task { @MainActor [weak self] in
                        await self?.refreshWarmCacheAfterStoreChange(change)
                    }
                    return
                }

                Task { @MainActor [weak self] in
                    await self?.refreshRecordAfterStoreChange(change)
                }
            }
            .store(in: &cancellables)
    }

    func refreshRecordAfterStoreChange(_ change: ClipboardRecordChange) async {
        let wasPanelActive = isPanelPresentationActive
        let previousFirstVisibleID = displayedItemsForInteraction.first?.id
        let shouldFollowTopInsertion =
            wasPanelActive &&
            change.kind == .upsert &&
            selectedItemIDs.count == 1 &&
            previousFirstVisibleID != nil &&
            selectedItemIDs.contains(previousFirstVisibleID!) &&
            lastSelectedID == previousFirstVisibleID

        if change.kind == .delete {
            performSilentListMutation {
                self.removeItem(withHash: change.contentHash)
            }
            if wasPanelActive {
                reconcileSelectionAfterDisplayedItemsChange()
            } else {
                clampSelectionToDisplayedItems()
            }
            return
        }

        guard let item = await StorageManager.shared.fetchItem(hash: change.contentHash) else {
            if wasPanelActive {
                loadData()
            } else {
                needsReloadOnNextPresentation = true
            }
            return
        }

        let routeKey = ClipboardRuntimeStore.shared.rootIdentity
        ClipboardHistoryWarmCache.shared.prependOrUpdate(item, routeKey: routeKey)

        // Same-hash replace: reconcile fields only — never animate a second insert
        // when an optimistic memory item already occupies this hash.
        let alreadyPresent = itemIndexByHash[item.contentHash] != nil
        performSilentListMutation {
            self.upsertItem(item, shouldResort: change.kind.requiresResort)
        }

        if wasPanelActive {
            reconcileSelectionAfterDisplayedItemsChange()
        } else {
            clampSelectionToDisplayedItems()
        }

        if shouldFollowTopInsertion,
           alreadyPresent == false,
           let previousFirstVisibleID,
           displayedItemsForInteraction.first?.id != previousFirstVisibleID {
            selectFirstDisplayedItem()
        }
    }

    /// When the panel VM has not been prepared yet, still keep warm cache current
    /// so the next open primes with the latest capture.
    func refreshWarmCacheAfterStoreChange(_ change: ClipboardRecordChange) async {
        guard change.kind != .delete else { return }
        guard let item = await StorageManager.shared.fetchItem(hash: change.contentHash) else {
            return
        }
        let routeKey = ClipboardRuntimeStore.shared.rootIdentity
        ClipboardHistoryWarmCache.shared.prependOrUpdate(item, routeKey: routeKey)
    }
}

private extension ClipboardRecordChangeKind {
    var requiresResort: Bool {
        switch self {
        case .upsert, .reorder:
            return true
        case .enrichment, .content, .delete:
            return false
        }
    }
}
