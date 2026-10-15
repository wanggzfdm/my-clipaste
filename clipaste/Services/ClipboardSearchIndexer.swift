import Foundation
import SQLite3

/// Local, rebuildable full-text index; it never opens the SwiftData store.
actor ClipboardSearchIndexer {
    struct Entry: Sendable {
        let id: UUID
        let plainText: String?
        let appName: String?
        let contentHash: String
        let typeRawValue: String
        let timestamp: Date
    }

    static let shared = ClipboardSearchIndexer()
    private var database: OpaquePointer?
    private var ready = false
    private var rebuilding = false
    private var databaseURL: URL?
    private var rebuildRequested = false
    private var rebuildTask: Task<Void, Never>?
    private var rebuildProvider: (@Sendable (Int, Int) async -> [Entry])?
    private var pendingUpserts: [Entry] = []
    private var pendingDeletes: Set<UUID> = []

    private init() {}

    func initialize(at url: URL? = nil) -> Bool {
        if ready {
            if let url, url != databaseURL { closeDatabase() } else { return true }
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dbURL = url ?? base.appendingPathComponent("Clipaste/search-fts.sqlite")
        do { try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { return false }
        guard sqlite3_open_v2(dbURL.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              execute("CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_fts USING fts5(id UNINDEXED, plainText, appName, contentHash UNINDEXED, typeRawValue UNINDEXED, timestamp UNINDEXED, tokenize='unicode61');") else {
            closeDatabase()
            return false
        }
        databaseURL = dbURL
        ready = true
        scheduleRequestedRebuildIfPossible()
        return true
    }

    func upsert(_ entry: Entry) -> Bool {
        guard ready else { return false }
        if rebuilding {
            pendingDeletes.remove(entry.id)
            pendingUpserts.append(entry)
            return true
        }
        guard execute("DELETE FROM clipboard_fts WHERE id = '\(entry.id.uuidString)';") else { return false }
        guard insert(entry) else {
            scheduleRebuild()
            return false
        }
        return true
    }

    func delete(ids: [UUID]) -> Bool {
        guard ready else { return false }
        if rebuilding {
            for id in ids { pendingDeletes.insert(id); pendingUpserts.removeAll { $0.id == id } }
            return true
        }
        return ids.allSatisfy { execute("DELETE FROM clipboard_fts WHERE id = '\($0.uuidString)';") }
    }

    func clear() -> Bool { ready && !rebuilding && execute("DELETE FROM clipboard_fts;") }

    func requestRebuild() {
        scheduleRebuild()
    }

    func configureRebuild(fetchPage: @escaping @Sendable (Int, Int) async -> [Entry]) {
        rebuildProvider = fetchPage
        scheduleRequestedRebuildIfPossible()
    }

    private func scheduleRebuild() {
        rebuildRequested = true
        scheduleRequestedRebuildIfPossible()
        NSLog("ClipboardSearchIndexer: index write failed; rebuild requested")
    }

    private func scheduleRequestedRebuildIfPossible() {
        guard rebuildRequested, ready, !rebuilding, rebuildTask == nil, let fetchPage = rebuildProvider else { return }
        rebuildTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            _ = await self.rebuild(fetchPage: fetchPage)
            await self.rebuildTaskFinished()
        }
    }

    private func rebuildTaskFinished() {
        rebuildTask = nil
        // A failed request is left pending for a later explicit request, avoiding a retry storm.
    }

    func rebuild(pageSize: Int = 500, fetchPage: @Sendable (Int, Int) async -> [Entry], shouldFail: @Sendable (Int) -> Bool = { _ in false }) async -> Bool {
        guard ready, !rebuilding else { return false }
        rebuilding = true
        defer { rebuilding = false }

        // 流式重建：先清空索引，然后分页 fetch + insert，避免全量快照累积内存
        guard execute("BEGIN IMMEDIATE;") else { return false }
        guard execute("DELETE FROM clipboard_fts;") else {
            _ = execute("ROLLBACK;")
            return false
        }

        var offset = 0
        while !Task.isCancelled {
            let entries = await fetchPage(pageSize, offset)
            guard !Task.isCancelled else {
                _ = execute("ROLLBACK;")
                return false
            }
            if shouldFail(offset) {
                _ = execute("ROLLBACK;")
                return false
            }
            if entries.isEmpty { break }
            for entry in entries where !Task.isCancelled {
                if !insert(entry) {
                    _ = execute("ROLLBACK;")
                    return false
                }
            }
            offset += entries.count
            await Task.yield()
        }

        guard !Task.isCancelled else {
            _ = execute("ROLLBACK;")
            return false
        }

        // 应用 pending upserts/deletes
        for id in pendingDeletes where !execute("DELETE FROM clipboard_fts WHERE id = '\(id.uuidString)';") {
            _ = execute("ROLLBACK;")
            return false
        }
        for entry in pendingUpserts where !insert(entry) {
            _ = execute("ROLLBACK;")
            return false
        }

        if execute("COMMIT;") {
            pendingDeletes.removeAll()
            pendingUpserts.removeAll()
            rebuildRequested = false
            return true
        }
        _ = execute("ROLLBACK;")
        pendingDeletes.removeAll()
        pendingUpserts.removeAll()
        return false
    }

    func search(_ query: String, limit: Int, offset: Int) -> [UUID]? {
        guard ready, !rebuilding, let statement = prepare("SELECT id FROM clipboard_fts WHERE clipboard_fts MATCH ? ORDER BY rank, CAST(timestamp AS REAL) DESC LIMIT ? OFFSET ?;") else { return nil }
        defer { sqlite3_finalize(statement) }
        let terms = Self.ftsTerms(query)
        guard !terms.isEmpty else { return nil }
        bind(terms, to: statement, at: 1)
        sqlite3_bind_int(statement, 2, Int32(clamping: max(1, limit)))
        sqlite3_bind_int(statement, 3, Int32(clamping: max(0, offset)))
        var ids: [UUID] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return ids }
            guard result == SQLITE_ROW, let text = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: text)) else { return nil }
            ids.append(id)
        }
    }

    private func insert(_ entry: Entry) -> Bool {
        withStatement("INSERT INTO clipboard_fts(id, plainText, appName, contentHash, typeRawValue, timestamp) VALUES(?, ?, ?, ?, ?, ?);") { statement in
            bind(entry.id.uuidString, to: statement, at: 1)
            bind(Self.searchableText(entry.plainText ?? ""), to: statement, at: 2)
            bind(entry.appName ?? "", to: statement, at: 3)
            bind(entry.contentHash, to: statement, at: 4)
            bind(entry.typeRawValue, to: statement, at: 5)
            bind(String(entry.timestamp.timeIntervalSince1970), to: statement, at: 6)
            return sqlite3_step(statement) == SQLITE_DONE
        }
    }

    private static func ftsTerms(_ text: String) -> String {
        let normalized = searchableText(text).unicodeScalars.map { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value)) ? " \(scalar) " : String(scalar)
        }.joined()
        let reservedOperators: Set<String> = ["AND", "OR", "NOT", "NEAR"]
        let terms = normalized.split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !reservedOperators.contains($0.uppercased()) }
        guard !terms.isEmpty else { return "" }
        return terms.map { "\"\($0)\"" }.joined(separator: " AND ")
    }

    /// Keep the original text for normal tokenization and add spaced CJK scalars so
    /// unicode61 can match substring queries inside otherwise-contiguous Chinese text.
    private static func searchableText(_ text: String) -> String {
        let cjkCharacters = text.unicodeScalars
            .filter { (0x4E00...0x9FFF).contains(Int($0.value)) }
            .map(String.init)
        guard !cjkCharacters.isEmpty else { return text }
        return text + " " + cjkCharacters.joined(separator: " ")
    }
    private func execute(_ sql: String) -> Bool { sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK }
    private func prepare(_ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        return statement
    }
    private func withStatement(_ sql: String, _ body: (OpaquePointer) -> Bool) -> Bool {
        guard let statement = prepare(sql) else { return false }
        defer { sqlite3_finalize(statement) }
        return body(statement)
    }
    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    private func closeDatabase() { if let database { sqlite3_close(database) }; database = nil; ready = false }
}
