import Foundation

/// Tracks whether a bounded history window is known to contain the whole history.
struct ClipboardHistoryPagingState: Equatable {
    private(set) var loadedCount = 0
    private(set) var hasLoadedFullHistory = false

    mutating func applyPage(count: Int, limit: Int) {
        loadedCount = count
        hasLoadedFullHistory = Self.isComplete(count: count, limit: limit)
    }

    mutating func applyWarmCache(count: Int, limit: Int) {
        applyPage(count: count, limit: limit)
    }

    mutating func stopAtBackgroundLimit(count: Int) {
        loadedCount = count
        hasLoadedFullHistory = false
    }

    static func isComplete(count: Int, limit: Int) -> Bool {
        count < limit
    }
}
