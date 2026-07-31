import Foundation

@main
@MainActor
struct ClipboardScopeCacheInvalidationTests {
    static func main() {
        testDeletingGroupInvalidatesOnlyMatchingKeys()
        testKeepingAllCacheRemovesNonAllKeys()
        testScopeCacheKeyPriority()
        testRemovalAndCapacityBehavior()
        print("ClipboardScopeCacheInvalidationTests: 4 passed")
    }

    private static func testDeletingGroupInvalidatesOnlyMatchingKeys() {
        let cache = makeCache()
        let allKey = ClipboardScopeKey.all(query: "")
        let groupA = ClipboardScopeKey.group(query: "", id: "a")
        let groupB = ClipboardScopeKey.group(query: "", id: "b")

        cache.insert(snapshot("all"), for: allKey)
        cache.insert(snapshot("groupA"), for: groupA)
        cache.insert(snapshot("groupB"), for: groupB)

        cache.remove { key in
            if case let .group(_, id) = key { return id == "a" }
            return false
        }

        precondition(cache.snapshot(for: allKey) != nil)
        precondition(cache.snapshot(for: groupA) == nil)
        precondition(cache.snapshot(for: groupB) != nil)
    }

    private static func testKeepingAllCacheRemovesNonAllKeys() {
        let cache = makeCache()
        let allKey = ClipboardScopeKey.all(query: "")
        let typeKey = ClipboardScopeKey.type(query: "", rawValue: "text")
        let pinnedKey = ClipboardScopeKey.pinned(query: "")

        cache.insert(snapshot("all"), for: allKey)
        cache.insert(snapshot("type"), for: typeKey)
        cache.insert(snapshot("pinned"), for: pinnedKey)

        cache.removeAll { key in
            if case .all = key { return true }
            return false
        }

        precondition(cache.snapshot(for: allKey) != nil)
        precondition(cache.snapshot(for: typeKey) == nil)
        precondition(cache.snapshot(for: pinnedKey) == nil)
    }

    private static func testScopeCacheKeyPriority() {
        let pinned = key(for: "q", groupID: "g", type: "text", builtIn: "favorites")
        let group = key(for: "q", groupID: "g", type: "text", builtIn: nil)
        let type = key(for: "q", groupID: nil, type: "text", builtIn: nil)
        let all = key(for: "q", groupID: nil, type: nil, builtIn: nil)

        precondition(pinned == .pinned(query: "q"))
        precondition(group == .group(query: "q", id: "g"))
        precondition(type == .type(query: "q", rawValue: "text"))
        precondition(all == .all(query: "q"))
    }

    private static func testRemovalAndCapacityBehavior() {
        let cache = ClipboardScopeCache<String>(capacity: 2)
        let first = ClipboardScopeKey.all(query: "")
        let second = ClipboardScopeKey.type(query: "", rawValue: "text")
        let third = ClipboardScopeKey.pinned(query: "")

        cache.insert(snapshot("one"), for: first)
        cache.insert(snapshot("two"), for: second)
        _ = cache.snapshot(for: first)
        cache.insert(snapshot("three"), for: third)

        precondition(cache.snapshot(for: first) != nil)
        precondition(cache.snapshot(for: second) == nil)
        precondition(cache.snapshot(for: third) != nil)
    }

    private static func makeCache() -> ClipboardScopeCache<String> {
        ClipboardScopeCache<String>(capacity: 8)
    }

    private static func snapshot(_ item: String) -> ClipboardScopeSnapshot<String> {
        ClipboardScopeSnapshot(items: [item], itemIDs: [UUID()], loadedCount: 1, hasMore: false, updatedAt: Date())
    }

    private static func key(for query: String, groupID: String?, type: String?, builtIn: String?) -> ClipboardScopeKey {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if builtIn == "favorites" { return .pinned(query: normalizedQuery) }
        if let groupID { return .group(query: normalizedQuery, id: groupID) }
        if let type { return .type(query: normalizedQuery, rawValue: type) }
        return .all(query: normalizedQuery)
    }
}
