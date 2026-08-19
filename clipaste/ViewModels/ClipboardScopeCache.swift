import Foundation

enum ClipboardScopeKey: Hashable, Sendable {
    case all(query: String)
    case group(query: String, id: String)
    case type(query: String, rawValue: String)
    case pinned(query: String)
}

struct ClipboardScopeSnapshot<Item> {
    let items: [Item]
    let itemIDs: [UUID]
    let loadedCount: Int
    let hasMore: Bool
    let updatedAt: Date
}

@MainActor
final class ClipboardScopeCache<Item> {
    private struct Entry {
        var snapshot: ClipboardScopeSnapshot<Item>
        var lastAccess: UInt64
    }

    private let capacity: Int
    private var nextAccess: UInt64 = 0
    private var entries: [ClipboardScopeKey: Entry] = [:]

    init(capacity: Int = 8) {
        self.capacity = max(capacity, 1)
    }

    // Explicit deinit avoids a Swift 6.3 Release inliner crash on generic class destroy.
    @inline(never)
    deinit {
        entries.removeAll(keepingCapacity: false)
    }

    func snapshot(for key: ClipboardScopeKey) -> ClipboardScopeSnapshot<Item>? {
        guard var entry = entries[key] else { return nil }

        nextAccess &+= 1
        entry.lastAccess = nextAccess
        entries[key] = entry
        return entry.snapshot
    }

    func insert(_ snapshot: ClipboardScopeSnapshot<Item>, for key: ClipboardScopeKey) {
        nextAccess &+= 1
        entries[key] = Entry(snapshot: snapshot, lastAccess: nextAccess)
        trimIfNeeded()
    }

    func remove(where predicate: (ClipboardScopeKey) -> Bool) {
        entries.keys.filter(predicate).forEach { entries.removeValue(forKey: $0) }
    }

    func removeAll(keeping predicate: (ClipboardScopeKey) -> Bool) {
        entries.keys.filter { !predicate($0) }.forEach { entries.removeValue(forKey: $0) }
    }

    private func trimIfNeeded() {
        while entries.count > capacity,
              let oldestKey = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            entries.removeValue(forKey: oldestKey)
        }
    }
}
