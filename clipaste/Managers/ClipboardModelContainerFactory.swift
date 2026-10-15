import Foundation
import SwiftData
import SQLite3

struct ClipboardRuntime: @unchecked Sendable {
    let container: ModelContainer
    let storage: StorageManager
}

final class ClipboardModelContainerFactory: @unchecked Sendable {
    nonisolated static let shared = ClipboardModelContainerFactory()

    private nonisolated init() {}

    nonisolated func makeRuntime(syncEnabled: Bool = false) throws -> ClipboardRuntime {
        let container = try makeContainer(syncEnabled: syncEnabled)
        return ClipboardRuntime(container: container, storage: StorageManager(modelContainer: container))
    }

    nonisolated func makeContainer(syncEnabled: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: ClipboardRecordSchemaV2.self)
        let localStoreURL = Self.localStoreURL
        Self.repairNullDeletedByDevice(in: localStoreURL)
        Self.applySQLitePragmas(in: localStoreURL)
        let configuration = ModelConfiguration(
            "ClipboardLocalStore", schema: schema, url: localStoreURL, cloudKitDatabase: .none)
        return try ModelContainer(
            for: schema, migrationPlan: ClipboardRecordMigrationPlan.self,
            configurations: [configuration])
    }

    nonisolated func makeInMemoryRuntime() throws -> ClipboardRuntime {
        let schema = Schema(versionedSchema: ClipboardRecordSchemaV2.self)
        let configuration = ModelConfiguration(
            "ClipboardRecoveryStore", schema: schema, isStoredInMemoryOnly: true,
            cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: schema, migrationPlan: ClipboardRecordMigrationPlan.self,
            configurations: [configuration])
        return ClipboardRuntime(container: container, storage: StorageManager(modelContainer: container))
    }

    private nonisolated static func applySQLitePragmas(in storeURL: URL) {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }

        var database: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            return
        }
        defer { sqlite3_close(database) }

        // 限制 SQLite page cache 大小，防止 881MB 数据库全量缓存到内存
        // cache_size = -2000 表示 2MB 缓存（每页 4KB × 500 页）
        _ = sqlite3_exec(database, "PRAGMA cache_size = -2000;", nil, nil, nil)
        // mmap_size 限制内存映射大小为 32MB
        _ = sqlite3_exec(database, "PRAGMA mmap_size = 33554432;", nil, nil, nil)
        // 启用 WAL 模式（如果尚未启用）
        _ = sqlite3_exec(database, "PRAGMA journal_mode = WAL;", nil, nil, nil)
    }

    private nonisolated static func repairNullDeletedByDevice(in storeURL: URL) {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }

        var database: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            return
        }
        defer { sqlite3_close(database) }

        var tableStatement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'ZCLIPBOARDGROUPMODEL' LIMIT 1",
            -1,
            &tableStatement,
            nil
        ) == SQLITE_OK else { return }
        defer { sqlite3_finalize(tableStatement) }
        guard sqlite3_step(tableStatement) == SQLITE_ROW else { return }

        var columnStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(ZCLIPBOARDGROUPMODEL)", -1, &columnStatement, nil) == SQLITE_OK,
              let columnStatement else { return }
        defer { sqlite3_finalize(columnStatement) }

        var hasDeletedByDevice = false
        while sqlite3_step(columnStatement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(columnStatement, 1),
                  String(cString: name) == "ZDELETEDBYDEVICE" else { continue }
            hasDeletedByDevice = true
            break
        }
        guard hasDeletedByDevice else { return }

        // Best-effort compatibility repair: never block opening the local SwiftData container.
        _ = sqlite3_exec(
            database,
            "UPDATE ZCLIPBOARDGROUPMODEL SET ZDELETEDBYDEVICE = '' WHERE ZDELETEDBYDEVICE IS NULL",
            nil,
            nil,
            nil
        )
    }

    nonisolated static var localStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "clipaste", isDirectory: true)
            .appendingPathComponent("Stores", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("clipboard-local.store", isDirectory: false)
    }
}
