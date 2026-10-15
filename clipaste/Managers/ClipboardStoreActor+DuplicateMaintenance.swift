import Foundation
import SwiftData

extension ClipboardStoreActor {
    func repairDuplicateRecords() -> Int {
        do {
            var counts: [String: Int] = [:]
            var rawHashes: [String: Set<String>] = [:]
            counts.reserveCapacity(4096)
            rawHashes.reserveCapacity(4096)

            let pageSize = 256
            var offset = 0

            while true {
                var descriptor = FetchDescriptor<ClipboardRecord>(
                    sortBy: [
                        SortDescriptor(\.timestamp, order: .reverse),
                        SortDescriptor(\.id, order: .forward)
                    ]
                )
                descriptor.fetchLimit = pageSize
                descriptor.fetchOffset = offset

                let records = try modelContext.fetch(descriptor)
                guard records.isEmpty == false else { break }

                for record in records {
                    let contentHash = record.contentHash.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard contentHash.isEmpty == false else { continue }
                    counts[contentHash, default: 0] += 1
                    rawHashes[contentHash, default: []].insert(record.contentHash)
                }

                offset += records.count
                guard records.count == pageSize else { break }
            }

            let duplicateHashes = counts.compactMap { $0.value > 1 ? $0.key : nil }
            guard duplicateHashes.isEmpty == false else { return 0 }

            var repairedCount = 0

            for hash in duplicateHashes {
                for storedHash in rawHashes[hash] ?? [] {
                    let dupDescriptor = FetchDescriptor<ClipboardRecord>(
                        predicate: #Predicate<ClipboardRecord> { record in
                            record.contentHash == storedHash
                        }
                    )
                    let duplicates = (try? modelContext.fetch(dupDescriptor)) ?? []
                    guard duplicates.count > 1 else { continue }

                    let orderedRecords = duplicates.sorted(by: shouldPreferSurvivor)
                    guard let survivor = orderedRecords.first else { continue }
                    for duplicate in orderedRecords.dropFirst() {
                        merge(duplicate, into: survivor)
                        modelContext.delete(duplicate)
                        repairedCount += 1
                    }
                    survivor.contentHash = hash
                }
            }

            if repairedCount > 0 {
                try markSyncAnchorUpdated()
                try modelContext.save()
            }

            return repairedCount
        } catch {
            print("❌ [ClipboardStoreActor] 修复重复记录失败: \(error)")
            return 0
        }
    }

    /// 把存量的超限内联文本迁移到 fullTextData(CKAsset 形态)。
    /// 单条超过 CloudKit 1MB 内联上限的记录会让整个导出队列卡死,
    /// 这个一次性修复能在不删数据的前提下疏通同步。
    func repairOversizedInlineTextRecords() async -> Int {
        var total = 0
        var offset = 0
        while !Task.isCancelled {
            let step = repairOversizedTextPage(offset: offset)
            total += step.repaired
            if step.isComplete { break }
            offset = step.nextOffset
            await Task.yield()
        }
        return total
    }

    func repairOversizedTextPage(offset: Int) -> RepairPageStep {
        do {
            let records = try fetchRecordPage(offset: offset)
            guard records.isEmpty == false else {
                return RepairPageStep(repaired: 0, nextOffset: offset, isComplete: true)
            }
            var repaired = 0
            for record in records {
                guard let text = record.plainText,
                      text.utf8.count > ClipboardTextSyncPolicy.inlineLimitBytes else {
                    continue
                }
                let storedText = ClipboardTextSyncPolicy.storedTextUsingPreferences(for: text)
                record.plainText = storedText.inlineText
                record.fullTextData = storedText.fullTextData
                record.isPlainTextTruncated = storedText.isTruncated
                repaired += 1
            }
            if repaired > 0 {
                try markSyncAnchorUpdated()
                try modelContext.save()
            }
            return RepairPageStep(repaired: repaired, nextOffset: offset + records.count, isComplete: records.count < Self.maintenancePageSize)
        } catch {
            print("❌ [ClipboardStoreActor] 修复超大文本记录失败: \(error)")
            return RepairPageStep(repaired: 0, nextOffset: offset, isComplete: true)
        }
    }
}
