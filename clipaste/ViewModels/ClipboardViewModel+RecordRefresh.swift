import AppKit
import Combine
import SwiftUI

extension ClipboardViewModel {
    func setupRecordChangeSubscriptions() {
        // 单次复制会连发最多 3 轮通知(upsert → 链接元数据 → 语法高亮),
        // 每轮各建一个新 ModelActor 做独立 DB 读 + 全量 UI 刷新。
        // 这里按 contentHash 在 80ms 窗口内合并:同 hash 只保留最强的 kind,
        // 一次 fetchItem 覆盖窗口内的全部字段变更。
        // 即时可见性不受影响——捕获时的乐观插入早已上屏。
        NotificationCenter.default.publisher(for: .clipboardRecordDidChange)
            .compactMap(\.clipboardRecordChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                self?.enqueueCoalescedRecordChange(change)
            }
            .store(in: &cancellables)
    }

    private func enqueueCoalescedRecordChange(_ change: ClipboardRecordChange) {
        if let pending = pendingRecordChangesByHash[change.contentHash] {
            pendingRecordChangesByHash[change.contentHash] = ClipboardRecordChange(
                contentHash: change.contentHash,
                kind: pending.kind.merged(with: change.kind)
            )
        } else {
            pendingRecordChangesByHash[change.contentHash] = change
        }

        guard pendingRecordChangeFlushTask == nil else { return }
        pendingRecordChangeFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard let self, Task.isCancelled == false else { return }
            self.pendingRecordChangeFlushTask = nil

            let changes = self.pendingRecordChangesByHash.values
            self.pendingRecordChangesByHash.removeAll()

            for change in changes {
                if self.hasPreparedPanelData == false {
                    await self.refreshWarmCacheAfterStoreChange(change)
                } else {
                    await self.refreshRecordAfterStoreChange(change)
                }
            }
        }
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

    /// 合并窗口内同 hash 的多轮变更时,保留语义最强的 kind:
    /// delete 终结一切;upsert/reorder 需要重排;enrichment 最弱。
    var coalescePriority: Int {
        switch self {
        case .delete: return 4
        case .upsert: return 3
        case .reorder: return 2
        case .content: return 1
        case .enrichment: return 0
        }
    }

    func merged(with other: ClipboardRecordChangeKind) -> ClipboardRecordChangeKind {
        coalescePriority >= other.coalescePriority ? self : other
    }
}
