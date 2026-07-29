import AppKit
import Combine
import SwiftUI

extension ClipboardViewModel {
    func selectGroup(_ groupID: UUID?) {
        selectedGroupID = groupID
    }

    func addNewGroup() {
        print("触发添加新分组")
    }

    func loadCustomGroups() {
        // 分组数据量极小,直接在 MainActor 用 mainContext 同步读取,
        // 避免 @ModelActor(Background QoS) 读被 MainActor(user-interactive) await
        // 产生的优先级反转 (Hang Risk)。
        let latestGroups = StorageManager.shared.fetchAllGroupsOnMain()
        applyCustomGroups(latestGroups)
    }

    func applyCustomGroups(_ latestGroups: [ClipboardGroupItem]) {
        customGroups = latestGroups

        if let selectedGroupId,
           latestGroups.contains(where: { $0.id == selectedGroupId }) == false {
            self.selectedGroupId = nil
        }

        if let draggedGroup,
           latestGroups.contains(where: { $0.id == draggedGroup.id }) == false {
            self.draggedGroup = nil
        }
    }

    func moveGroup(from sourceId: String, relativeTo destinationId: String, insertAfter: Bool) {
        guard sourceId != destinationId,
              let sourceIndex = customGroups.firstIndex(where: { $0.id == sourceId }),
              customGroups.contains(where: { $0.id == destinationId }) else { return }

        let draggedGroup = customGroups.remove(at: sourceIndex)
        guard let destinationIndex = customGroups.firstIndex(where: { $0.id == destinationId }) else {
            customGroups.insert(draggedGroup, at: min(sourceIndex, customGroups.count))
            return
        }

        let insertionIndex = insertAfter ? destinationIndex + 1 : destinationIndex
        customGroups.insert(draggedGroup, at: min(max(insertionIndex, 0), customGroups.count))
    }

    func saveGroupOrder() {
        StorageManager.shared.updateGroupOrder(groupIDs: customGroups.map(\.id))
    }

    func createNewGroup(name: String, systemIconName: String? = nil) {
        StorageManager.shared.createGroup(name: name, systemIconName: systemIconName)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            self.loadCustomGroups()
        }
    }

    func assignItemToGroup(item: ClipboardItem, group: ClipboardGroupItem) {
        updateItem(id: item.id) { updatedItem in
            if updatedItem.groupIDs.contains(group.id) == false {
                updatedItem.groupIDs.append(group.id)
            }
        }

        StorageManager.shared.assignToGroup(hash: item.contentHash, groupId: group.id)
    }

    func renameGroup(group: ClipboardGroupItem, newName: String) {
        if let index = customGroups.firstIndex(where: { $0.id == group.id }) {
            customGroups[index] = ClipboardGroupItem(id: group.id, name: newName, systemIconName: group.systemIconName, sortOrder: group.sortOrder)
        }
        StorageManager.shared.renameGroup(id: group.id, newName: newName)
    }

    func updateGroupIcon(group: ClipboardGroupItem, newIcon: String?) {
        if let index = customGroups.firstIndex(where: { $0.id == group.id }) {
            customGroups[index] = ClipboardGroupItem(id: group.id, name: group.name, systemIconName: newIcon, sortOrder: group.sortOrder)
        }
        StorageManager.shared.updateGroupIcon(id: group.id, newIcon: newIcon)
    }

    func deleteGroup(group: ClipboardGroupItem) {
        if selectedGroupId == group.id {
            selectedGroupId = nil
        }
        if draggedGroup?.id == group.id {
            draggedGroup = nil
        }
        withAnimation {
            customGroups.removeAll(where: { $0.id == group.id })
            for index in 0..<items.count {
                if items[index].groupIDs.contains(group.id) {
                    items[index].groupIDs.removeAll(where: { $0 == group.id })
                }
            }
            refreshDisplayedItemsFromCurrentScope()
        }
        StorageManager.shared.deleteGroup(id: group.id)
    }

    var visibleSmartFilters: [ClipboardContentType] {
        isSmartGroupsEnabled ? ClipboardContentType.filterCategories : []
    }

    var visibleBuiltInGroups: [ClipboardBuiltInGroup] {
        [.favorites]
    }

    var isAllScopeSelected: Bool {
        currentFilter == nil && selectedBuiltInGroup == nil && selectedGroupId == nil
    }

    func isSmartFilterSelected(_ type: ClipboardContentType) -> Bool {
        currentFilter == type && selectedBuiltInGroup == nil && selectedGroupId == nil
    }

    func isBuiltInGroupSelected(_ group: ClipboardBuiltInGroup) -> Bool {
        selectedBuiltInGroup == group && currentFilter == nil && selectedGroupId == nil
    }

    func isCustomGroupSelected(_ groupID: String) -> Bool {
        selectedGroupId == groupID
    }

    func showAllItems() {
        activateDisplayedScope(filter: nil, builtInGroup: nil, groupID: nil)
    }

    func showCustomGroup(_ groupID: String) {
        activateDisplayedScope(filter: nil, builtInGroup: nil, groupID: groupID)
    }

    func showSmartFilter(_ type: ClipboardContentType) {
        activateDisplayedScope(filter: type, builtInGroup: nil, groupID: nil)
    }

    func showBuiltInGroup(_ group: ClipboardBuiltInGroup) {
        activateDisplayedScope(filter: nil, builtInGroup: group, groupID: nil)
    }

    func selectNextGroup() {
        let slots = unifiedGroups
        guard slots.count > 1 else { return }
        let index = slots.firstIndex(of: currentSlot) ?? 0
        let next = (index + 1) % slots.count
        applySlot(slots[next])
    }

    func selectPreviousGroup() {
        let slots = unifiedGroups
        guard slots.count > 1 else { return }
        let index = slots.firstIndex(of: currentSlot) ?? 0
        let previous = (index - 1 + slots.count) % slots.count
        applySlot(slots[previous])
    }

    func setupGroupSwitchSubscriptions() {
        NotificationCenter.default.publisher(for: .selectNextGroup)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.selectNextGroup() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .selectPreviousGroup)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.selectPreviousGroup() }
            .store(in: &cancellables)
    }

    func setupSmartGroupsGuard() {
        UserDefaults.standard.publisher(for: \.enable_smart_groups)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let slots = self.unifiedGroups
                if !slots.contains(self.currentSlot), let first = slots.first {
                    self.applySlot(first)
                }
            }
            .store(in: &cancellables)
    }
}

private extension ClipboardViewModel {
    var unifiedGroups: [UnifiedGroupSlot] {
        var slots: [UnifiedGroupSlot] = [.all]
        slots += customGroups.map { .userGroup($0.id) }
        slots += visibleBuiltInGroups.map { .builtIn($0) }
        if isSmartGroupsEnabled {
            slots += ClipboardContentType.filterCategories.map { .smartFilter($0) }
        }
        return slots
    }

    var currentSlot: UnifiedGroupSlot {
        if let groupId = selectedGroupId {
            return .userGroup(groupId)
        }
        if let filter = currentFilter {
            return .smartFilter(filter)
        }
        if let selectedBuiltInGroup {
            return .builtIn(selectedBuiltInGroup)
        }
        return .all
    }

    func applySlot(_ slot: UnifiedGroupSlot) {
        switch slot {
        case .all:
            showAllItems()
        case .smartFilter(let type):
            showSmartFilter(type)
        case .builtIn(let group):
            showBuiltInGroup(group)
        case .userGroup(let id):
            showCustomGroup(id)
        }
    }

    func activateDisplayedScope(filter: ClipboardContentType?, builtInGroup: ClipboardBuiltInGroup?, groupID: String?) {
        guard currentFilter != filter || selectedBuiltInGroup != builtInGroup || selectedGroupId != groupID else {
            return
        }

        shouldResetSelectionToFirstDisplayedItem = true
        currentFilter = filter
        selectedBuiltInGroup = builtInGroup
        selectedGroupId = groupID

        // 同帧刷新 + 静默 transaction：避免 Empty/List 切换与 ForEach 插入动画造成闪烁。
        // 同时 bump filterGeneration 并短暂 suppress pipeline，吞掉 Combine 对同一次 scope 变更的二次 rematerialize。
        filterGeneration &+= 1
        suppressFilterPipelineEcho = true

        // 即将走 DB 首屏的 scope：内存未命中时不要先清空列表（Empty→LazyHStack 会像从右飞入）。
        let willFetchScopeFromDB: Bool = {
            if builtInGroup == .favorites { return true }
            if groupID != nil || filter != nil { return true }
            // 「全部」也会 loadData / 搜索分页
            if groupID == nil, filter == nil, builtInGroup == nil { return true }
            return false
        }()

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if willFetchScopeFromDB {
                applyMemoryScopePreferringNonEmptyDisplay()
            } else {
                refreshDisplayedItemsFromCurrentScope()
                reconcileSelectionAfterDisplayedItemsChange()
            }
        }

        // 用户分组 / 类型 / 收藏：DB 首屏，避免只显示内存窗口内的命中。
        if let builtInGroup, builtInGroup == .favorites {
            beginScopePagination(groupId: nil, typeRawValue: nil, pinnedOnly: true)
        } else if builtInGroup == nil, groupID != nil || filter != nil {
            beginScopePagination(groupId: groupID, typeRawValue: filter?.rawValue, pinnedOnly: false)
        } else if groupID == nil, filter == nil, builtInGroup == nil {
            // 回到「全部」：重置为无 scope 的按需分页首屏。
            let q = activeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty {
                loadData(mode: .visibleFirst)
            } else {
                beginSearchPagination(query: q)
            }
        } else if displayedItems.isEmpty, hasLoadedFullHistory == false {
            isInitialHistoryLoading = true
        }

        // 下一 runloop 再放开 pipeline，避免同一次 CombineLatest 回声
        DispatchQueue.main.async { [weak self] in
            self?.suppressFilterPipelineEcho = false
        }
    }

    /// 内存能命中则立刻换到新 scope；命中为空则保持旧画面并打 loading，等 DB 页无动画替换。
    private func applyMemoryScopePreferringNonEmptyDisplay() {
        let query = activeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let memoryIDs = items.compactMap { item -> UUID? in
            matchesCurrentDisplayScope(item, query: query) ? item.id : nil
        }

        if memoryIDs.isEmpty == false {
            publishDisplayedItemIDs(memoryIDs)
            reconcileSelectionAfterDisplayedItemsChange()
            return
        }

        // 保持当前 displayed*，避免 MainView 走 EmptyState 分支。
        isInitialHistoryLoading = true
        isLoadingMoreHistory = true
    }
}
