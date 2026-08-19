import Foundation
import SQLite3

/// Lightweight presence-flag repair that never faults external blob bytes.
///
/// Core Data stores external-storage attributes as non-NULL tokens (or inline
/// payloads) in SQLite. Presence Bools can be derived with `IS NOT NULL`
/// without opening `_EXTERNAL_DATA` files or pinning `_PFExternalReferenceData`.
enum ExternalPresenceSQLBackfill {
    enum BackfillError: Error, LocalizedError {
        case openFailed(String)
        case execFailed(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let message):
                return "Unable to open clipboard store for presence backfill: \(message)"
            case .execFailed(let message):
                return "Presence backfill SQL failed: \(message)"
            }
        }
    }

    /// Returns the number of rows whose presence flags were updated.
    static func apply(to storeURL: URL) throws -> Int {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let openCode = sqlite3_open_v2(storeURL.path, &database, flags, nil)
        guard openCode == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let database {
                sqlite3_close_v2(database)
            }
            throw BackfillError.openFailed(message)
        }
        defer { sqlite3_close_v2(database) }

        // Don't wait forever if SwiftData holds a write lock.
        _ = sqlite3_busy_timeout(database, 5_000)

        // Bump Z_OPT so any already-registered SwiftData objects observe a
        // version change and re-fault scalar flags on next access.
        let sql = """
        UPDATE ZCLIPBOARDRECORD SET
          ZHASPREVIEWIMAGEDATA = CASE WHEN ZPREVIEWIMAGEDATA IS NOT NULL THEN 1 ELSE 0 END,
          ZHASORIGINALIMAGEDATA = CASE WHEN ZIMAGEDATA IS NOT NULL THEN 1 ELSE 0 END,
          ZHASLINKICONDATA = CASE WHEN ZLINKICONDATA IS NOT NULL THEN 1 ELSE 0 END,
          ZHASRTFDATA = CASE WHEN ZRTFDATA IS NOT NULL THEN 1 ELSE 0 END,
          ZHASRICHTEXTARCHIVEDATA = CASE WHEN ZRICHTEXTARCHIVEDATA IS NOT NULL THEN 1 ELSE 0 END,
          Z_OPT = IFNULL(Z_OPT, 0) + 1
        WHERE
          IFNULL(ZHASPREVIEWIMAGEDATA, 0) != CASE WHEN ZPREVIEWIMAGEDATA IS NOT NULL THEN 1 ELSE 0 END
          OR IFNULL(ZHASORIGINALIMAGEDATA, 0) != CASE WHEN ZIMAGEDATA IS NOT NULL THEN 1 ELSE 0 END
          OR IFNULL(ZHASLINKICONDATA, 0) != CASE WHEN ZLINKICONDATA IS NOT NULL THEN 1 ELSE 0 END
          OR IFNULL(ZHASRTFDATA, 0) != CASE WHEN ZRTFDATA IS NOT NULL THEN 1 ELSE 0 END
          OR IFNULL(ZHASRICHTEXTARCHIVEDATA, 0) != CASE WHEN ZRICHTEXTARCHIVEDATA IS NOT NULL THEN 1 ELSE 0 END;
        """

        var errorMessage: UnsafeMutablePointer<CChar>?
        let execCode = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if execCode != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            if let errorMessage {
                sqlite3_free(errorMessage)
            }
            throw BackfillError.execFailed(message)
        }

        return Int(sqlite3_changes(database))
    }

    /// Content hashes that appear more than once. Empty means no SwiftData full-table fetch is needed.
    static func duplicateContentHashes(in storeURL: URL) throws -> [String] {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let openCode = sqlite3_open_v2(storeURL.path, &database, flags, nil)
        guard openCode == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let database {
                sqlite3_close_v2(database)
            }
            throw BackfillError.openFailed(message)
        }
        defer { sqlite3_close_v2(database) }
        _ = sqlite3_busy_timeout(database, 5_000)

        let sql = """
        SELECT ZCONTENTHASH
        FROM ZCLIPBOARDRECORD
        WHERE ZCONTENTHASH IS NOT NULL AND LENGTH(TRIM(ZCONTENTHASH)) > 0
        GROUP BY ZCONTENTHASH
        HAVING COUNT(*) > 1;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BackfillError.execFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var hashes: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let cString = sqlite3_column_text(statement, 0) {
                hashes.append(String(cString: cString))
            }
        }
        return hashes
    }
}
