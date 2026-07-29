import Foundation

/// 历史列表分页游标。与 `ClipboardViewModel.pagination` 一一对应。
struct HistoryPaginationState: Equatable {
    var loadedCount: Int = 0
    var pageSize: Int = 64
    var hasMore: Bool = true
    var isLoading: Bool = false
    /// 与 dataLoadGeneration 对齐：loadData / scope 重置时递增。
    var generation: UInt = 0
    /// 当前分页所绑定的搜索词（trim 后）；切换 query 时必须重置游标。
    var activeQuery: String = ""
    /// 用户分组 scope（DB predicate）；nil 表示不限分组。
    var scopeGroupId: String? = nil
    /// 类型过滤 rawValue；nil 表示不限类型。
    var scopeTypeRawValue: String? = nil
    /// 仅收藏（isPinned）；对应 built-in favorites。
    var scopePinnedOnly: Bool = false
}

/// 纯逻辑：是否应在尾部触发续页（不依赖 SwiftData / MainActor）。
enum HistoryPaginationPolicy {
    static func shouldLoadMore(
        currentID: UUID,
        displayedIDs: [UUID],
        state: HistoryPaginationState,
        prefetchDistance: Int
    ) -> Bool {
        guard state.hasMore, state.isLoading == false else { return false }
        guard displayedIDs.isEmpty == false else { return false }
        guard let index = displayedIDs.firstIndex(of: currentID) else { return false }
        let threshold = max(displayedIDs.count - prefetchDistance, 0)
        return index >= threshold
    }
}
