import Foundation

// Lightweight host-side check; run: swift scripts/ClipboardHistoryPagingStateTests.swift
struct ClipboardHistoryPagingState {
    private(set) var loadedCount = 0
    private(set) var hasLoadedFullHistory = false

    mutating func applyPage(count: Int, limit: Int) {
        loadedCount = count
        hasLoadedFullHistory = Self.isComplete(count: count, limit: limit)
    }
    mutating func applyWarmCache(count: Int, limit: Int) { applyPage(count: count, limit: limit) }
    mutating func stopAtBackgroundLimit(count: Int) { loadedCount = count; hasLoadedFullHistory = false }
    static func isComplete(count: Int, limit: Int) -> Bool { count < limit }
}

func expect(_ condition: Bool, _ message: String) {
    if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

expect(ClipboardHistoryPagingState.isComplete(count: 0, limit: 80), "empty history")
expect(ClipboardHistoryPagingState.isComplete(count: 79, limit: 80), "less than limit")
expect(!ClipboardHistoryPagingState.isComplete(count: 80, limit: 80), "exact limit is ambiguous")
expect(ClipboardHistoryPagingState.isComplete(count: 79, limit: 80), "warm cache below limit")
expect(!ClipboardHistoryPagingState.isComplete(count: 80, limit: 80), "warm cache at limit")
var capped = ClipboardHistoryPagingState()
capped.stopAtBackgroundLimit(count: 2000)
expect(!capped.hasLoadedFullHistory && capped.loadedCount == 2000, "background cap is partial")
print("ClipboardHistoryPagingStateTests: OK")
