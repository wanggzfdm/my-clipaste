import Foundation

enum ClipboardSearchResultPolicy {
    nonisolated static func shouldFallbackAfterFetchFailure<T, E: Error>(_ result: Result<T, E>) -> Bool {
        if case .failure = result { return true }
        return false
    }
}
