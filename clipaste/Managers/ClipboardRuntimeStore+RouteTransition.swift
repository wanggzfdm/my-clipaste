import Foundation

@MainActor
extension ClipboardRuntimeStore {
    func rebuildRuntime(syncEnabled: Bool, mergeCurrentStore: Bool = false) async {
        defaults.set(false, forKey: "enable_icloud_sync")
    }

    func mergeStoreInBatches(from sourceStorage: StorageManager, into targetStorage: StorageManager) async throws -> (records: Int, groups: Int) {
        let groups = try await sourceStorage.exportGroups()
        if !groups.isEmpty {
            try await targetStorage.importStoreExport(ClipboardStoreExport(records: [], groups: groups))
        }
        let count = try await BoundedBatchTransfer.run(
            batchSize: 128,
            loadBatch: { offset, limit in try await sourceStorage.exportRecordBatch(offset: offset, limit: limit) },
            consumeBatch: { records in try await targetStorage.importStoreExport(ClipboardStoreExport(records: records, groups: [])) })
        return (count, groups.count)
    }
}
