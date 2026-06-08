import AppKit
import Combine
import SwiftUI

extension ClipboardViewModel {
    func setupRecordChangeSubscriptions() {
        NotificationCenter.default.publisher(for: .clipboardRecordDidChange)
            .compactMap(\.clipboardRecordChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self, self.hasPreparedPanelData else { return }

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
            removeItem(withHash: change.contentHash)
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

        upsertItem(item, shouldResort: change.kind.requiresResort)
        if wasPanelActive {
            reconcileSelectionAfterDisplayedItemsChange()
        } else {
            clampSelectionToDisplayedItems()
        }

        if shouldFollowTopInsertion,
           let previousFirstVisibleID,
           displayedItemsForInteraction.first?.id != previousFirstVisibleID {
            selectFirstDisplayedItem()
        }
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
