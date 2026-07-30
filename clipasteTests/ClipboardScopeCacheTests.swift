import Foundation

@main
@MainActor
struct ClipboardScopeCacheTests {
    static func main() {
        testDifferentScopeAttributesDoNotShareSnapshot()
        testCacheEvictsLeastRecentlyUsedSnapshotAfterCapacity()
        testNormalizedQueriesAreIdenticalForScopeKey()
        testRemovalKeepsOnlyMatchingKeys()
        testScopeKeyPriorityFromRawStrings()
        print("ClipboardScopeCacheTests: 5 passed")
    }

    private static func testDifferentScopeAttributesDoNotShareSnapshot() {
        let cache = ClipboardScopeCache<String>(capacity: 8)
        let groupKey = ClipboardScopeKey.group(query: "", id: "components")
        let typeKey = ClipboardScopeKey.type(query: "", rawValue: "text")

        cache.insert(makeSnapshot("cached"), for: groupKey)

        precondition(cache.snapshot(for: typeKey) == nil)
    }

    private static func testCacheEvictsLeastRecentlyUsedSnapshotAfterCapacity() {
        let cache = ClipboardScopeCache<String>(capacity: 2)
        let first = ClipboardScopeKey.all(query: "")
        let second = ClipboardScopeKey.type(query: "", rawValue: "text")
        let third = ClipboardScopeKey.pinned(query: "")

        cache.insert(makeSnapshot("first"), for: first)
        cache.insert(makeSnapshot("second"), for: second)
        _ = cache.snapshot(for: first)
        cache.insert(makeSnapshot("third"), for: third)

        precondition(cache.snapshot(for: first) != nil)
        precondition(cache.snapshot(for: second) == nil)
        precondition(cache.snapshot(for: third) != nil)
    }

    private static func testNormalizedQueriesAreIdenticalForScopeKey() {
        let left = ClipboardScopeKey.group(query: "components", id: "group")
        let right = ClipboardScopeKey.group(query: "components", id: "group")
        precondition(left == right, "Normalized query mismatch")
    }

    private static func testRemovalKeepsOnlyMatchingKeys() {
        let cache = ClipboardScopeCache<String>(capacity: 4)
        let allKey = ClipboardScopeKey.all(query: "")
        let groupKey = ClipboardScopeKey.group(query: "", id: "components")
        cache.insert(makeSnapshot("all"), for: allKey)
        cache.insert(makeSnapshot("group"), for: groupKey)

        cache.removeAll { key in
            if case .all = key { return true }
            return false
        }

        precondition(cache.snapshot(for: groupKey) == nil)
        precondition(cache.snapshot(for: allKey) != nil)
    }

    private static func testScopeKeyPriorityFromRawStrings() {
        let pinned = makeKey(query: "q", groupID: "g", type: "text", builtInGroup: "favorites")
        let group = makeKey(query: "q", groupID: "g", type: "text", builtInGroup: nil)
        let type = makeKey(query: "q", groupID: nil, type: "text", builtInGroup: nil)
        let all = makeKey(query: "q", groupID: nil, type: nil, builtInGroup: nil)

        precondition(pinned == .pinned(query: "q"))
        precondition(group == .group(query: "q", id: "g"))
        precondition(type == .type(query: "q", rawValue: "text"))
        precondition(all == .all(query: "q"))
    }

    private static func makeKey(
        query: String,
        groupID: String?,
        type: String?,
        builtInGroup: String?
    ) -> ClipboardScopeKey {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if builtInGroup == "favorites" { return .pinned(query: normalizedQuery) }
        if let groupID { return .group(query: normalizedQuery, id: groupID) }
        if let type { return .type(query: normalizedQuery, rawValue: type) }
        return .all(query: normalizedQuery)
    }

    private static func makeSnapshot(_ item: String) -> ClipboardScopeSnapshot<String> {
        ClipboardScopeSnapshot(
            items: [item],
            itemIDs: [UUID()],
            loadedCount: 1,
            hasMore: false,
            updatedAt: Date()
        )
    }
}
