import Foundation
import SQLite3

@main
struct ExternalPresenceSQLBackfillTests {
    static func main() {
        testUpdatesMismatchedFlagsOnly()
        testIdempotentSecondPass()
        testDuplicateContentHashes()
        print("ExternalPresenceSQLBackfillTests: 3 passed")
    }

    private static func testUpdatesMismatchedFlagsOnly() {
        let dbURL = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dbURL) }

        exec(dbURL, """
        CREATE TABLE ZCLIPBOARDRECORD (
          Z_PK INTEGER PRIMARY KEY,
          Z_OPT INTEGER,
          ZPREVIEWIMAGEDATA BLOB,
          ZIMAGEDATA BLOB,
          ZLINKICONDATA BLOB,
          ZRTFDATA BLOB,
          ZRICHTEXTARCHIVEDATA BLOB,
          ZHASPREVIEWIMAGEDATA INTEGER,
          ZHASORIGINALIMAGEDATA INTEGER,
          ZHASLINKICONDATA INTEGER,
          ZHASRTFDATA INTEGER,
          ZHASRICHTEXTARCHIVEDATA INTEGER
        );
        INSERT INTO ZCLIPBOARDRECORD VALUES
          (1, 1, X'01', NULL, X'02', NULL, X'03', 0, 0, 0, 0, 0),
          (2, 1, NULL, NULL, NULL, NULL, NULL, 0, 0, 0, 0, 0),
          (3, 1, X'AA', X'BB', NULL, X'CC', NULL, 1, 1, 0, 1, 0);
        """)

        let changed = try! ExternalPresenceSQLBackfill.apply(to: dbURL)
        precondition(changed == 1, "expected only mismatched row updated, got \(changed)")

        let row1 = queryFlags(dbURL, pk: 1)
        precondition(row1 == (1, 0, 1, 0, 1))
        let row2 = queryFlags(dbURL, pk: 2)
        precondition(row2 == (0, 0, 0, 0, 0))
        let row3 = queryFlags(dbURL, pk: 3)
        precondition(row3 == (1, 1, 0, 1, 0))
    }

    private static func testIdempotentSecondPass() {
        let dbURL = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dbURL) }

        exec(dbURL, """
        CREATE TABLE ZCLIPBOARDRECORD (
          Z_PK INTEGER PRIMARY KEY,
          Z_OPT INTEGER,
          ZPREVIEWIMAGEDATA BLOB,
          ZIMAGEDATA BLOB,
          ZLINKICONDATA BLOB,
          ZRTFDATA BLOB,
          ZRICHTEXTARCHIVEDATA BLOB,
          ZHASPREVIEWIMAGEDATA INTEGER,
          ZHASORIGINALIMAGEDATA INTEGER,
          ZHASLINKICONDATA INTEGER,
          ZHASRTFDATA INTEGER,
          ZHASRICHTEXTARCHIVEDATA INTEGER
        );
        INSERT INTO ZCLIPBOARDRECORD VALUES
          (1, 1, X'01', NULL, NULL, NULL, NULL, 0, 0, 0, 0, 0);
        """)

        let first = try! ExternalPresenceSQLBackfill.apply(to: dbURL)
        precondition(first == 1)
        let second = try! ExternalPresenceSQLBackfill.apply(to: dbURL)
        precondition(second == 0)
    }

    
    private static func testDuplicateContentHashes() {
        let dbURL = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        exec(dbURL, """
        CREATE TABLE ZCLIPBOARDRECORD (
          Z_PK INTEGER PRIMARY KEY,
          ZCONTENTHASH VARCHAR
        );
        INSERT INTO ZCLIPBOARDRECORD VALUES
          (1, 'aaa'),
          (2, 'aaa'),
          (3, 'bbb'),
          (4, 'ccc'),
          (5, 'ccc'),
          (6, 'ccc');
        """)
        let hashes = try! ExternalPresenceSQLBackfill.duplicateContentHashes(in: dbURL).sorted()
        precondition(hashes == ["aaa", "ccc"], "got \(hashes)")
    }

    // MARK: - helpers

    private static func makeTempStore() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("presence-backfill-\(UUID().uuidString).sqlite")
    }

    private static func exec(_ url: URL, _ sql: String) {
        var db: OpaquePointer?
        precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, sql, nil, nil, &err)
        if code != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "?"
            if let err { sqlite3_free(err) }
            preconditionFailure("sql failed: \(message)")
        }
    }

    private static func queryFlags(_ url: URL, pk: Int) -> (Int, Int, Int, Int, Int) {
        var db: OpaquePointer?
        precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        SELECT ZHASPREVIEWIMAGEDATA, ZHASORIGINALIMAGEDATA, ZHASLINKICONDATA,
               ZHASRTFDATA, ZHASRICHTEXTARCHIVEDATA
        FROM ZCLIPBOARDRECORD WHERE Z_PK = \(pk);
        """
        var stmt: OpaquePointer?
        precondition(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        precondition(sqlite3_step(stmt) == SQLITE_ROW)
        return (
            Int(sqlite3_column_int(stmt, 0)),
            Int(sqlite3_column_int(stmt, 1)),
            Int(sqlite3_column_int(stmt, 2)),
            Int(sqlite3_column_int(stmt, 3)),
            Int(sqlite3_column_int(stmt, 4))
        )
    }
}
