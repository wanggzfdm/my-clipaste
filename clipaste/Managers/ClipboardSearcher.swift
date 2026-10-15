import Foundation
import SwiftData

@ModelActor
actor ClipboardSearcher {
    func searchAndMap(searchText: String, fetchLimit: Int? = nil, offset: Int = 0) async -> [ClipboardItem] {
        let query = searchText
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let ids = await ClipboardSearchIndexer.shared.search(query, limit: fetchLimit ?? 200, offset: offset) {
            guard !ids.isEmpty else { return [] }
            let idSet = Set(ids)
            let descriptor = FetchDescriptor<ClipboardRecord>(predicate: #Predicate { idSet.contains($0.id) })
            let fetched = Result { try modelContext.fetch(descriptor) }
            guard !ClipboardSearchResultPolicy.shouldFallbackAfterFetchFailure(fetched), case let .success(records) = fetched else {
                return fallbackSearch(query, fetchLimit: fetchLimit, offset: offset)
            }
            let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            return ids.compactMap { byID[$0] }.map(ClipboardRecordSnapshot.makeFromRecord).map(StorageManager.makeClipboardItem)
        }
        return fallbackSearch(query, fetchLimit: fetchLimit, offset: offset)
    }

    func fetchByScope(
        groupId: String?,
        favoritesOnly: Bool,
        typeFilterRawValue: String?,
        fetchLimit: Int?,
        offset: Int
    ) async -> [ClipboardItem] {
        let sortBy: [SortDescriptor<ClipboardRecord>] = [SortDescriptor(\.timestamp, order: .reverse)]

        var descriptor: FetchDescriptor<ClipboardRecord>

        if let groupId {
            if favoritesOnly {
                if let typeFilterRawValue {
                    let pred = #Predicate<ClipboardRecord> { record in
                        (record.groupId == groupId || (record.groupIdsRaw?.contains(groupId) ?? false))
                        && record.isPinned == true
                        && record.typeRawValue == typeFilterRawValue
                    }
                    descriptor = FetchDescriptor(predicate: pred, sortBy: sortBy)
                } else {
                    let pred = #Predicate<ClipboardRecord> { record in
                        (record.groupId == groupId || (record.groupIdsRaw?.contains(groupId) ?? false))
                        && record.isPinned == true
                    }
                    descriptor = FetchDescriptor(predicate: pred, sortBy: sortBy)
                }
            } else {
                if let typeFilterRawValue {
                    let pred = #Predicate<ClipboardRecord> { record in
                        (record.groupId == groupId || (record.groupIdsRaw?.contains(groupId) ?? false))
                        && record.typeRawValue == typeFilterRawValue
                    }
                    descriptor = FetchDescriptor(predicate: pred, sortBy: sortBy)
                } else {
                    let pred = #Predicate<ClipboardRecord> { record in
                        record.groupId == groupId || (record.groupIdsRaw?.contains(groupId) ?? false)
                    }
                    descriptor = FetchDescriptor(predicate: pred, sortBy: sortBy)
                }
            }
        } else if favoritesOnly {
            if let typeFilterRawValue {
                let pred = #Predicate<ClipboardRecord> { record in
                    record.isPinned == true && record.typeRawValue == typeFilterRawValue
                }
                descriptor = FetchDescriptor(predicate: pred, sortBy: sortBy)
            } else {
                let pred = #Predicate<ClipboardRecord> { record in
                    record.isPinned == true
                }
                descriptor = FetchDescriptor(predicate: pred, sortBy: sortBy)
            }
        } else if let typeFilterRawValue {
            let pred = #Predicate<ClipboardRecord> { record in
                record.typeRawValue == typeFilterRawValue
            }
            descriptor = FetchDescriptor(predicate: pred, sortBy: sortBy)
        } else {
            descriptor = FetchDescriptor(sortBy: sortBy)
        }

        if let fetchLimit, fetchLimit > 0 {
            descriptor.fetchLimit = fetchLimit
        }
        if offset > 0 {
            descriptor.fetchOffset = offset
        }

        let records = (try? modelContext.fetch(descriptor)) ?? []

        let filtered = records.filter { record in
            if let groupId {
                let groupIDs = normalizedGroupIDs(primaryGroupID: record.groupId, groupIdsRaw: record.groupIdsRaw)
                if groupIDs.contains(groupId) == false {
                    return false
                }
            }
            return true
        }

        return filtered.map { record in
            ClipboardRecordSnapshot.makeFromRecord(record)
        }.map { StorageManager.makeClipboardItem(from: $0) }
    }

    private func fallbackSearch(_ query: String, fetchLimit: Int?, offset: Int) -> [ClipboardItem] {
        var descriptor: FetchDescriptor<ClipboardRecord>

        if query.isEmpty {
            descriptor = FetchDescriptor<ClipboardRecord>(
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
        } else {
            let predicate = #Predicate<ClipboardRecord> { record in
                (record.plainText?.localizedStandardContains(query) == true) ||
                (record.appLocalizedName?.localizedStandardContains(query) == true)
            }

            descriptor = FetchDescriptor<ClipboardRecord>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
        }

        // 当调用方未指定 fetchLimit 时，使用默认上限避免全表扫描
        if let fetchLimit, fetchLimit > 0 {
            descriptor.fetchLimit = fetchLimit
        } else {
            descriptor.fetchLimit = 200
        }

        if offset > 0 {
            descriptor.fetchOffset = offset
        }

        let records = (try? modelContext.fetch(descriptor)) ?? []
        let snapshots = records.map { record in
            ClipboardRecordSnapshot.makeFromRecord(record)
        }

        return snapshots.map { StorageManager.makeClipboardItem(from: $0) }
    }
}
