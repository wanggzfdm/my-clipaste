import Foundation
import SwiftData

extension StorageManager {
    nonisolated func searchIndexEntries(limit: Int, offset: Int) async -> [ClipboardSearchIndexer.Entry] {
        let container = self.container
        return await detachedRead {
            let actor = ClipboardStoreActor(modelContainer: container)
            return await actor.searchIndexEntries(limit: limit, offset: offset)
        }
    }

    nonisolated
    func fetchItemsInBackground(
        searchText: String,
        container: ModelContainer,
        fetchLimit: Int? = nil,
        offset: Int = 0
    ) async -> [ClipboardItem] {
        await detachedRead {
            let searcher = ClipboardSearcher(modelContainer: container)
            return await searcher.searchAndMap(searchText: searchText, fetchLimit: fetchLimit, offset: offset)
        }
    }

    nonisolated
    func fetchItemsPage(searchText: String, fetchLimit: Int, offset: Int = 0) async -> [ClipboardItem] {
        let container = self.container
        return await detachedRead {
            let searcher = ClipboardSearcher(modelContainer: container)
            return await searcher.searchAndMap(searchText: searchText, fetchLimit: fetchLimit, offset: offset)
        }
    }

    nonisolated
    func fetchItemsByScope(
        groupId: String?,
        favoritesOnly: Bool,
        typeFilterRawValue: String?,
        fetchLimit: Int? = nil,
        offset: Int = 0
    ) async -> [ClipboardItem] {
        let container = self.container
        return await detachedRead {
            let searcher = ClipboardSearcher(modelContainer: container)
            return await searcher.fetchByScope(
                groupId: groupId,
                favoritesOnly: favoritesOnly,
                typeFilterRawValue: typeFilterRawValue,
                fetchLimit: fetchLimit,
                offset: offset
            )
        }
    }

    func fetchGroups() async -> [ClipboardGroupItem] {
        await storeActor.fetchAllGroups()
    }

    @MainActor
    func fetchAllGroupsOnMain() -> [ClipboardGroupItem] {
        let context = container.mainContext
        let descriptor = FetchDescriptor<ClipboardGroupModel>(predicate: #Predicate { $0.deletedAt == nil }, sortBy: [SortDescriptor(\.sortOrder, order: .forward)])
        return ((try? context.fetch(descriptor)) ?? []).map {
            ClipboardGroupItem(id: $0.id, name: $0.name, systemIconName: $0.resolvedSystemIconName, sortOrder: $0.sortOrder)
        }
    }

    func fetchItem(hash: String) async -> ClipboardItem? {
        let container = self.container
        let snapshot = await detachedRead {
            let actor = ClipboardStoreActor(modelContainer: container)
            return await actor.fetchRecordSnapshot(hash: hash)
        }
        guard let snapshot else { return nil }
        return StorageManager.makeClipboardItem(from: snapshot)
    }

    func diagnosticsSnapshot() async -> ClipboardStoreDiagnosticsSnapshot {
        let container = self.container
        return await detachedRead {
            let actor = ClipboardStoreActor(modelContainer: container)
            return await actor.diagnosticsSnapshot()
        }
    }

    nonisolated func repairImportedMigrationTimestampsInBackground() -> Task<Int, Never> {
        let container = self.container
        return Task.detached(priority: .utility) {
            var offset = 0
            var count = 0
            while !Task.isCancelled {
                let actor = ClipboardStoreActor(modelContainer: container)
                let step = await actor.repairImportedMigrationTimestampsPage(offset: offset)
                count += step.repairedCount
                if step.isComplete { break }
                offset = step.nextOffset
                await Task.yield()
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            }
            return count
        }
    }

    func repairImportedMigrationTimestampsIfNeeded() async -> Int {
        await repairImportedMigrationTimestampsInBackground().value
    }

    func repairTextClassificationsIfNeeded() async -> Int {
        let container = self.container
        return await Task.detached(priority: .utility) {
            var total = 0
            var offset = 0
            while !Task.isCancelled {
                let actor = ClipboardStoreActor(modelContainer: container)
                let step = await actor.repairTextClassificationsPage(offset: offset)
                total += step.repaired
                if step.isComplete { break }
                offset = step.nextOffset
                await Task.yield()
            }
            return total
        }.value
    }
    func touchSyncAnchor() async throws { try await storeActor.touchSyncAnchor() }
    func repairDuplicateRecords() async -> Int {
        let container = self.container
        return await Task.detached(priority: .utility) {
            let actor = ClipboardStoreActor(modelContainer: container)
            return await actor.repairDuplicateRecords()
        }.value
    }
    func repairOversizedInlineTextRecords() async -> Int {
        let container = self.container
        return await Task.detached(priority: .utility) {
            var total = 0
            var offset = 0
            while !Task.isCancelled {
                let actor = ClipboardStoreActor(modelContainer: container)
                let step = await actor.repairOversizedTextPage(offset: offset)
                total += step.repaired
                if step.isComplete { break }
                offset = step.nextOffset
                await Task.yield()
            }
            return total
        }.value
    }
    func fetchDistinctAppBundleIDsForColorRepair() async -> [String] {
        let container = self.container
        return await Task.detached(priority: .utility) {
            let actor = ClipboardStoreActor(modelContainer: container)
            return await actor.fetchDistinctAppBundleIDsForColorRepair()
        }.value
    }
    func repairAppIconDominantColors(using colorsByBundleID: [String: String]) async -> Int {
        let container = self.container
        return await Task.detached(priority: .utility) {
            var total = 0
            var offset = 0
            while !Task.isCancelled {
                let actor = ClipboardStoreActor(modelContainer: container)
                let step = await actor.repairAppIconColorsPage(offset: offset, colors: colorsByBundleID)
                total += step.repaired
                if step.isComplete { break }
                offset = step.nextOffset
                await Task.yield()
            }
            return total
        }.value
    }
    func fetchDistinctAppBundleIDsMissingIconData() async -> [String] {
        let container = self.container
        return await Task.detached(priority: .utility) {
            let actor = ClipboardStoreActor(modelContainer: container)
            return await actor.fetchDistinctAppBundleIDsMissingIconData()
        }.value
    }
    func repairAppIconData(using iconDataByBundleID: [String: Data]) async -> Int {
        let container = self.container
        return await Task.detached(priority: .utility) {
            var total = 0
            var offset = 0
            while !Task.isCancelled {
                let actor = ClipboardStoreActor(modelContainer: container)
                let step = await actor.repairAppIconDataPage(offset: offset, iconData: iconDataByBundleID)
                total += step.repaired
                if step.isComplete { break }
                offset = step.nextOffset
                await Task.yield()
            }
            return total
        }.value
    }

    func exportGroups() async throws -> [ClipboardGroupExport] {
        let container = self.container
        return try await Task.detached(priority: .utility) {
            try await ClipboardStoreActor(modelContainer: container).exportGroups()
        }.value
    }

    func exportRecordBatch(offset: Int, limit: Int) async throws -> [ClipboardRecordExport] {
        let container = self.container
        return try await Task.detached(priority: .utility) {
            try await ClipboardStoreActor(modelContainer: container).exportRecordBatch(offset: offset, limit: limit)
        }.value
    }

    func exportPinnedRecordBatch(offset: Int, limit: Int) async throws -> ClipboardStoreExport {
        let container = self.container
        return try await Task.detached(priority: .utility) {
            try await ClipboardStoreActor(modelContainer: container).exportPinnedRecordBatch(offset: offset, limit: limit)
        }.value
    }

    func importStoreExport(_ payload: ClipboardStoreExport) async throws { try await storeActor.importStoreExport(payload) }

    func loadPreviewImageData(id: UUID) async -> Data? {
        let container = self.container
        return await detachedRead {
            let actor = ClipboardStoreActor(modelContainer: container)
            return await actor.loadPreviewImageData(id: id)
        }
    }

    func loadPlainText(id: UUID) async -> String? {
        let container = self.container
        return await detachedRead {
            let actor = ClipboardStoreActor(modelContainer: container)
            return await actor.loadPlainText(id: id)
        }
    }

    func loadAppIconDominantColorHex(id: UUID) async -> String? {
        let container = self.container
        return await detachedRead {
            let actor = ClipboardStoreActor(modelContainer: container)
            return await actor.loadAppIconDominantColorHex(id: id)
        }
    }

    func loadAppIconData(id: UUID) async -> Data? {
        let container = self.container
        return await detachedRead {
            let actor = ClipboardStoreActor(modelContainer: container)
            return await actor.loadAppIconData(id: id)
        }
    }

    func loadPasteRecord(id: UUID) async -> ClipboardPasteRecord? {
        let container = self.container
        return await detachedRead {
            let actor = ClipboardStoreActor(modelContainer: container)
            return await actor.loadPasteRecord(id: id)
        }
    }

    func loadOriginalImageData(id: UUID) async -> Data? {
        let container = self.container
        return await detachedRead {
            let actor = ClipboardStoreActor(modelContainer: container)
            return await actor.loadOriginalImageData(id: id)
        }
    }

    func loadImageData(id: UUID) async -> Data? {
        let container = self.container
        return await detachedRead {
            let actor = ClipboardStoreActor(modelContainer: container)
            return await actor.loadImageData(id: id)
        }
    }

    func loadRTFData(id: UUID) async -> Data? {
        let container = self.container
        return await detachedRead {
            let actor = ClipboardStoreActor(modelContainer: container)
            return await actor.loadRTFData(id: id)
        }
    }

    func loadImageUTType(id: UUID) async -> String? {
        let container = self.container
        return await detachedRead {
            let actor = ClipboardStoreActor(modelContainer: container)
            return await actor.loadImageUTType(id: id)
        }
    }
}
