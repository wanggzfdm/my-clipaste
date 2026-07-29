import AppKit
import SwiftUI

extension ClipboardViewModel {
    func handleSelection(id: UUID, isCommand: Bool, isShift: Bool) {
        if isShift, let anchorID = lastSelectedID {
            let source = displayedItemsForInteraction
            if let anchorIdx = source.firstIndex(where: { $0.id == anchorID }),
               let targetIdx = source.firstIndex(where: { $0.id == id }) {
                let range = min(anchorIdx, targetIdx)...max(anchorIdx, targetIdx)
                let rangeIDs = Set(source[range].map(\.id))
                selectedItemIDs.formUnion(rangeIDs)
            }
        } else if isCommand {
            if selectedItemIDs.contains(id) {
                selectedItemIDs.remove(id)
            } else {
                selectedItemIDs.insert(id)
            }
            lastSelectedID = id
        } else {
            selectedItemIDs = [id]
            lastSelectedID = id
        }

        prewarmQuickLookPreviewIfNeeded()
    }

    func selectAll() {
        selectedItemIDs = Set(displayedItemIDs)
    }

    func clearSelection() {
        selectedItemIDs.removeAll()
        lastSelectedID = nil
    }

    func ensureListSelection() {
        guard let firstVisible = displayedItemsForInteraction.first else { return }

        if selectedItemIDs.isEmpty {
            selectedItemIDs = [firstVisible.id]
            lastSelectedID = firstVisible.id
            requestListScroll(to: firstVisible.id, animated: false)
            prewarmQuickLookPreviewIfNeeded()
            return
        }

        if let lastSelectedID,
           displayedItemsForInteraction.contains(where: { $0.id == lastSelectedID }),
           selectedItemIDs.contains(lastSelectedID) {
            return
        }

        if let selectedVisibleID = displayedItemsForInteraction.first(where: { selectedItemIDs.contains($0.id) })?.id {
            lastSelectedID = selectedVisibleID
            prewarmQuickLookPreviewIfNeeded()
            return
        }

        selectedItemIDs = [firstVisible.id]
        lastSelectedID = firstVisible.id
        requestListScroll(to: firstVisible.id, animated: false)
        prewarmQuickLookPreviewIfNeeded()
    }

    func selectFirstDisplayedItem(animatedScroll: Bool = false) {
        guard let firstVisible = displayedItemsForInteraction.first else {
            clearSelection()
            return
        }

        selectedItemIDs = [firstVisible.id]
        lastSelectedID = firstVisible.id
        requestListScroll(to: firstVisible.id, animated: animatedScroll)
        prewarmQuickLookPreviewIfNeeded()
    }

    func userDidSelect(item: ClipboardItem) {
        handleSelection(id: item.id, isCommand: false, isShift: false)
    }

    func moveSelection(direction: Int) {
        // 使用完整 ID 列表导航，避免大列表分帧物化未完成时只能在首窗内移动。
        let ids = displayedItemIDs
        guard !ids.isEmpty else { return }

        let currentIndex = lastSelectedID.flatMap { lid in
            ids.firstIndex(of: lid)
        }

        let nextIndex: Int
        if let idx = currentIndex {
            nextIndex = min(max(idx + direction, 0), ids.count - 1)
        } else {
            nextIndex = direction > 0 ? 0 : ids.count - 1
        }

        let nextID = ids[nextIndex]
        withAnimation(.easeInOut(duration: 0.1)) {
            selectedItemIDs = [nextID]
            lastSelectedID = nextID
        }

        requestListScroll(to: nextID, animated: true)
        // 确保目标项已物化（分帧过程中可能尚未进入 displayedItems）
        ensureDisplayedItemMaterialized(around: nextIndex)
        prewarmQuickLookPreviewIfNeeded()
    }

    var displayedItemsForInteraction: [ClipboardItem] {
        // 物化完成时直接用缓存；否则按 ID 解析，保证交互不依赖首窗。
        if displayedItems.count == displayedItemIDs.count {
            return displayedItems
        }
        return displayedItemIDs.compactMap { item(for: $0) }
    }

    func selectionCandidateAfterRemoving(ids removedIDs: Set<UUID>) -> UUID? {
        let displayedItems = displayedItemsForInteraction
        guard let firstRemovedIndex = displayedItems.firstIndex(where: { removedIDs.contains($0.id) }) else {
            return nil
        }

        let remainingItems = displayedItems.filter { removedIDs.contains($0.id) == false }
        guard !remainingItems.isEmpty else {
            return nil
        }

        let candidateIndex = min(firstRemovedIndex, remainingItems.count - 1)
        return remainingItems[candidateIndex].id
    }

    func applySelectionAfterDeletion(
        fallbackID: UUID?,
        preservedSelectionIDs: Set<UUID> = []
    ) {
        let visibleIDs = Set(displayedItemsForInteraction.map(\.id))
        let remainingPreservedIDs = preservedSelectionIDs.intersection(visibleIDs)

        if !remainingPreservedIDs.isEmpty {
            selectedItemIDs = remainingPreservedIDs

            if let lastSelectedID, remainingPreservedIDs.contains(lastSelectedID) == false {
                self.lastSelectedID = displayedItemsForInteraction.first(where: {
                    remainingPreservedIDs.contains($0.id)
                })?.id
            } else if lastSelectedID == nil {
                self.lastSelectedID = displayedItemsForInteraction.first(where: {
                    remainingPreservedIDs.contains($0.id)
                })?.id
            }

            prewarmQuickLookPreviewIfNeeded()
            return
        }

        guard let fallbackID, visibleIDs.contains(fallbackID) else {
            clearSelection()
            return
        }

        selectedItemIDs = [fallbackID]
        lastSelectedID = fallbackID
        prewarmQuickLookPreviewIfNeeded()
    }

    func reconcileSelectionAfterDisplayedItemsChange() {
        if shouldResetSelectionToFirstDisplayedItem {
            shouldResetSelectionToFirstDisplayedItem = false

            if isSearchFilteringActive == false {
                selectFirstDisplayedItem()
                return
            }
        }

        clampSelectionToDisplayedItems()
    }

    func clampSelectionToDisplayedItems() {
        let visibleIDs = Set(displayedItemIDs)

        if !selectedItemIDs.isSubset(of: visibleIDs) {
            selectedItemIDs.formIntersection(visibleIDs)
        }

        if let lastSelectedID, !visibleIDs.contains(lastSelectedID) {
            self.lastSelectedID = selectedItemIDs.first
        }

        if let quickLookItem, !visibleIDs.contains(quickLookItem.id) {
            dismissQuickLook()
        }
    }

    /// 键盘导航到尚未物化的区域时，扩展物化窗口以包含目标。
    func ensureDisplayedItemMaterialized(around index: Int) {
        guard displayedItemIDs.indices.contains(index) else { return }
        if displayedItems.indices.contains(index),
           displayedItems[index].id == displayedItemIDs[index] {
            return
        }
        // 触发一次针对前缀的加速物化（含目标 index）
        let end = min(displayedItemIDs.count, max(index + 1, Self.displayMaterializeWindowSize))
        let prefixIDs = Array(displayedItemIDs.prefix(end))
        let materialised = prefixIDs.compactMap { item(for: $0) }
        if materialised.count > displayedItems.count {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                displayedItems = materialised
            }
        }
    }
}
