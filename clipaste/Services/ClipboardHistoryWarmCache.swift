import Foundation

/// In-memory first-page history cache for panel open latency.
/// Uses a lock instead of an actor so the hot path can hydrate without awaiting.
final class ClipboardHistoryWarmCache: @unchecked Sendable {
    static let shared = ClipboardHistoryWarmCache()
    static let defaultLimit = 80

    private let lock = NSLock()
    private var routeKey: String?
    private var items: [ClipboardItem] = []

    private init() {}

    func update(items: [ClipboardItem], routeKey: String) {
        lock.lock()
        defer { lock.unlock() }
        self.routeKey = routeKey
        self.items = items
    }

    /// Insert or replace a single item at the front of the warm cache (by content hash).
    /// Hot-path safe: no await, lock only.
    func prependOrUpdate(_ item: ClipboardItem, routeKey: String) {
        lock.lock()
        defer { lock.unlock() }

        if self.routeKey != routeKey {
            self.routeKey = routeKey
            self.items = [item]
            return
        }

        items.removeAll { $0.contentHash == item.contentHash || $0.id == item.id }
        items.insert(item, at: 0)
        if items.count > Self.defaultLimit {
            items = Array(items.prefix(Self.defaultLimit))
        }
    }

    func snapshot(for routeKey: String) -> [ClipboardItem]? {
        lock.lock()
        defer { lock.unlock() }
        guard self.routeKey == routeKey, items.isEmpty == false else {
            return nil
        }
        return items
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        routeKey = nil
        items = []
    }
}

extension Notification.Name {
    static let clipboardWarmCacheDidChange = Notification.Name("clipboardWarmCacheDidChange")
}

struct ClipboardWarmCacheChange: Sendable {
    let routeKey: String
}

extension Notification {
    var clipboardWarmCacheChange: ClipboardWarmCacheChange? {
        guard name == .clipboardWarmCacheDidChange,
              let routeKey = userInfo?["routeKey"] as? String else {
            return nil
        }

        return ClipboardWarmCacheChange(routeKey: routeKey)
    }
}
