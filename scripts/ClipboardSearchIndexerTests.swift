import Foundation
import SQLite3

@main
struct ClipboardSearchIndexerTests {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("search-fts.sqlite")
        let index = ClipboardSearchIndexer.shared
        let initialized = await index.initialize(at: url)
        precondition(initialized)
        let first = UUID(), second = UUID(), stale = UUID()
        @Sendable func entry(_ id: UUID, _ text: String, _ stamp: Double) -> ClipboardSearchIndexer.Entry {
            .init(id: id, plainText: text, appName: "Editor", contentHash: "hash", typeRawValue: "text", timestamp: Date(timeIntervalSince1970: stamp))
        }
        let initial = entry(first, "齐天大圣 mixed English", 100)
        let inserted = await index.upsert(initial)
        precondition(inserted)
        let chinese = await index.search("大圣", limit: 10, offset: 0)
        let english = await index.search("English", limit: 10, offset: 0)
        precondition(chinese?.contains(first) == true && english?.contains(first) == true)
        for query in ["mixed\" OR *", "English OR NOT", "(English)", "\"English\""] {
            let hits = await index.search(query, limit: 10, offset: 0)
            precondition(hits?.contains(first) == true, "ordinary query terms remain searchable: \\(query)")
        }
        for query in ["OR", "not", "NEAR", "***", "( AND )"] {
            let hits = await index.search(query, limit: 10, offset: 0)
            precondition(hits == nil, "operator-only or punctuation-only query is safely empty: \\(query)")
        }
        let updated = await index.upsert(entry(first, "Phoenix refreshed", 200))
        let oldHits = await index.search("齐天", limit: 10, offset: 0)
        let newHits = await index.search("Phoenix", limit: 10, offset: 0)
        precondition(updated && oldHits?.isEmpty == true && newHits?.contains(first) == true)
        let staleInserted = await index.upsert(entry(stale, "obsolete marker", 50))
        precondition(staleInserted)
        let rows = [entry(first, "Phoenix refreshed", 200), entry(second, "Phoenix second", 100)]
        let failed = await index.rebuild(fetchPage: { _, offset in
            offset == 0 ? [entry(second, "partial", 100)] : []
        }, shouldFail: { $0 == 1 })
        let preserved = await index.search("obsolete", limit: 10, offset: 0)
        precondition(!failed && preserved?.contains(stale) == true)
        let cancellationTask = Task {
            await index.rebuild(fetchPage: { _, _ in
                try? await Task.sleep(for: .milliseconds(200))
                return []
            })
        }
        try? await Task.sleep(for: .milliseconds(20))
        cancellationTask.cancel()
        let cancelled = await cancellationTask.value
        let preservedAfterCancellation = await index.search("obsolete", limit: 10, offset: 0)
        precondition(!cancelled && preservedAfterCancellation?.contains(stale) == true)
        let rebuilt = await index.rebuild { limit, offset in Array(rows.dropFirst(offset).prefix(limit)) }
        let obsoleteHits = await index.search("obsolete", limit: 10, offset: 0)
        let page = await index.search("Phoenix", limit: 1, offset: 1)
        let deleted = await index.delete(ids: [first])
        let remaining = await index.search("Phoenix", limit: 10, offset: 0)
        precondition(rebuilt && obsoleteHits?.isEmpty == true && page?.count == 1 && deleted && remaining?.count == 1)
        try? FileManager.default.removeItem(at: directory)
        print("ClipboardSearchIndexerTests passed: insert/update/delete/rebuild stale removal/pagination/special characters/Chinese-English; failed and cancelled rebuilds preserve old entries")
    }
}
