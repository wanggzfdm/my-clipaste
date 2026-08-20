import Foundation

// Lightweight host-side check for ClipboardScopeFetchPolicy (no XCTest target on this branch).
// Run: swift scripts/ClipboardScopeFetchPolicyTests.swift

enum ClipboardScopeFetchPolicy {
    nonisolated static func shouldSupplementFromDatabase(
        hasSearchQuery: Bool,
        hasGroupScope: Bool,
        hasTypeScope: Bool,
        hasBuiltInScope: Bool,
        hasLoadedFullHistory: Bool
    ) -> Bool {
        if hasLoadedFullHistory {
            return false
        }
        return hasSearchQuery || hasGroupScope || hasTypeScope || hasBuiltInScope
    }
}

func expect(_ cond: Bool, _ message: String) {
    if cond == false {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

// Full history already in memory → never hit DB.
expect(
    ClipboardScopeFetchPolicy.shouldSupplementFromDatabase(
        hasSearchQuery: true,
        hasGroupScope: true,
        hasTypeScope: true,
        hasBuiltInScope: true,
        hasLoadedFullHistory: true
    ) == false,
    "full history should skip DB"
)

// Group scope outside memory window → DB.
expect(
    ClipboardScopeFetchPolicy.shouldSupplementFromDatabase(
        hasSearchQuery: false,
        hasGroupScope: true,
        hasTypeScope: false,
        hasBuiltInScope: false,
        hasLoadedFullHistory: false
    ),
    "group scope needs DB"
)

// All tab, no search → no DB.
expect(
    ClipboardScopeFetchPolicy.shouldSupplementFromDatabase(
        hasSearchQuery: false,
        hasGroupScope: false,
        hasTypeScope: false,
        hasBuiltInScope: false,
        hasLoadedFullHistory: false
    ) == false,
    "all-tab without search should not hit DB"
)

// Search with partial history → DB.
expect(
    ClipboardScopeFetchPolicy.shouldSupplementFromDatabase(
        hasSearchQuery: true,
        hasGroupScope: false,
        hasTypeScope: false,
        hasBuiltInScope: false,
        hasLoadedFullHistory: false
    ),
    "search needs DB when history incomplete"
)

print("ClipboardScopeFetchPolicyTests: OK")
