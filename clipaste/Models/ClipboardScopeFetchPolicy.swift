import Foundation

/// Decides when the UI should hit SwiftData for scoped tabs.
///
/// The main history window only keeps the newest ~2000 records in memory.
/// User groups / type filters / favorites often point at older rows outside
/// that window, so memory-only filtering shows an empty list even though the
/// store still has matches.
enum ClipboardScopeFetchPolicy {
    nonisolated static func shouldSupplementFromDatabase(
        hasSearchQuery: Bool,
        hasGroupScope: Bool,
        hasTypeScope: Bool,
        hasBuiltInScope: Bool,
        hasLoadedFullHistory: Bool
    ) -> Bool {
        if hasLoadedFullHistory {
            // Everything already sits in the in-memory window; filtering is enough.
            return false
        }

        return hasSearchQuery || hasGroupScope || hasTypeScope || hasBuiltInScope
    }
}
