import Foundation

@main
@MainActor
struct ClipboardScopeCacheTests {
    static func main() {
        testDifferentScopeAttributesDoNotShareSnapshot()
        testCacheEvictsLeastRecentlyUsedSnapshotAfterCapacity()
        print("ClipboardScopeCacheTests: 2 passed")
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
