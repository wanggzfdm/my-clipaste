import Foundation
import SwiftData

extension ClipboardStoreActor {
    struct ImportedTimestampRepairStep: Sendable {
        let nextOffset: Int
        let repairedCount: Int
        let isComplete: Bool
    }

    func repairImportedMigrationTimestampsPage(offset: Int) -> ImportedTimestampRepairStep {
        let calendar = Calendar(identifier: .gregorian)
        let suspiciousUpperBound = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1)) ?? .distantPast
        do {
            let migratedBundleIdentifiers = MigrationManager.migratedBundleIdentifiers
            let now = Date()
            let records = try fetchRecordPage(offset: offset)
            guard records.isEmpty == false else {
                return ImportedTimestampRepairStep(nextOffset: offset, repairedCount: 0, isComplete: true)
            }

            var repairedCount = 0
            for record in records {
                guard record.timestamp < suspiciousUpperBound,
                      let appBundleID = record.appBundleID,
                      migratedBundleIdentifiers.contains(appBundleID),
                      let repairedDate = MigrationManager.repairedDateIfLikelyMisdecodedReferenceTimestamp(
                        record.timestamp,
                        now: now
                      ) else {
                    continue
                }
                record.timestamp = repairedDate
                repairedCount += 1
            }
            if repairedCount > 0 { try modelContext.save() }
            // 释放本页缓存，避免全表扫描内存累积
            let nextOffset = offset + records.count
            return ImportedTimestampRepairStep(
                nextOffset: nextOffset,
                repairedCount: repairedCount,
                isComplete: records.count < Self.maintenancePageSize
            )
        } catch {
            print("❌ [ClipboardStoreActor] 修复迁移时间戳失败: \(error)")
            return ImportedTimestampRepairStep(nextOffset: offset, repairedCount: 0, isComplete: true)
        }
    }

    func repairTextClassificationsIfNeeded() async -> Int {
        var total = 0
        var offset = 0
        while !Task.isCancelled {
            let step = repairTextClassificationsPage(offset: offset)
            total += step.repaired
            if step.isComplete { break }
            offset = step.nextOffset
            await Task.yield()
        }
        return total
    }

    struct RepairPageStep: Sendable {
        let repaired: Int
        let nextOffset: Int
        let isComplete: Bool
    }

    func repairTextClassificationsPage(offset: Int) -> RepairPageStep {
        do {
            let records = try fetchRecordPage(offset: offset)
            guard records.isEmpty == false else {
                return RepairPageStep(repaired: 0, nextOffset: offset, isComplete: true)
            }
            var repaired = 0
            for record in records {
                guard let text = record.plainText?.trimmingCharacters(in: .whitespacesAndNewlines),
                      text.isEmpty == false,
                      textBasedTypes.contains(record.typeRawValue) else {
                    continue
                }
                let reclassifiedType = ClipboardContentClassifier.classify(text).rawValue
                guard reclassifiedType != record.typeRawValue else { continue }
                record.typeRawValue = reclassifiedType
                repaired += 1
            }
            if repaired > 0 { try modelContext.save() }
            return RepairPageStep(repaired: repaired, nextOffset: offset + records.count, isComplete: records.count < Self.maintenancePageSize)
        } catch {
            print("❌ [ClipboardStoreActor] 修复文本分类失败: \(error)")
            return RepairPageStep(repaired: 0, nextOffset: offset, isComplete: true)
        }
    }

    func fetchDistinctAppBundleIDsForColorRepair() -> [String] {
        var orderedBundleIDs: [String] = []
        var seenBundleIDs: Set<String> = []
        var offset = 0

        while true {
            let records: [ClipboardRecord]
            do {
                records = try fetchRecordPage(offset: offset)
            } catch {
                print("❌ [ClipboardStoreActor] 读取待修复 App 图标颜色失败: \(error)")
                return orderedBundleIDs
            }
            guard records.isEmpty == false else { break }

            for record in records {
                guard let bundleID = record.appBundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      bundleID.isEmpty == false,
                      seenBundleIDs.insert(bundleID).inserted else {
                    continue
                }
                orderedBundleIDs.append(bundleID)
            }
            offset += records.count
            guard records.count == Self.maintenancePageSize else { break }
        }

        return orderedBundleIDs
    }

    func repairAppIconDominantColors(using colorsByBundleID: [String: String]) async -> Int {
        guard colorsByBundleID.isEmpty == false else { return 0 }
        var total = 0
        var offset = 0
        while !Task.isCancelled {
            let step = repairAppIconColorsPage(offset: offset, colors: colorsByBundleID)
            total += step.repaired
            if step.isComplete { break }
            offset = step.nextOffset
            await Task.yield()
        }
        return total
    }

    func repairAppIconColorsPage(offset: Int, colors: [String: String]) -> RepairPageStep {
        guard colors.isEmpty == false else {
            return RepairPageStep(repaired: 0, nextOffset: offset, isComplete: true)
        }
        do {
            let records = try fetchRecordPage(offset: offset)
            guard records.isEmpty == false else {
                return RepairPageStep(repaired: 0, nextOffset: offset, isComplete: true)
            }
            var repaired = 0
            for record in records {
                guard let bundleID = record.appBundleID,
                      let repairedColor = colors[bundleID],
                      record.appIconDominantColorHex != repairedColor else {
                    continue
                }
                record.appIconDominantColorHex = repairedColor
                repaired += 1
            }
            if repaired > 0 { try modelContext.save() }
            return RepairPageStep(repaired: repaired, nextOffset: offset + records.count, isComplete: records.count < Self.maintenancePageSize)
        } catch {
            print("❌ [ClipboardStoreActor] 修复 App 图标主色失败: \(error)")
            return RepairPageStep(repaired: 0, nextOffset: offset, isComplete: true)
        }
    }

    func fetchDistinctAppBundleIDsMissingIconData() -> [String] {
        var orderedBundleIDs: [String] = []
        var seenBundleIDs: Set<String> = []
        var offset = 0

        while true {
            let records: [ClipboardRecord]
            do {
                records = try fetchRecordPage(offset: offset)
            } catch {
                print("❌ [ClipboardStoreActor] 读取待修复 App 图标数据失败: \(error)")
                return orderedBundleIDs
            }
            guard records.isEmpty == false else { break }

            for record in records {
                guard record.appIconData == nil,
                      let bundleID = record.appBundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      bundleID.isEmpty == false,
                      seenBundleIDs.insert(bundleID).inserted else {
                    continue
                }
                orderedBundleIDs.append(bundleID)
            }
            offset += records.count
            guard records.count == Self.maintenancePageSize else { break }
        }

        return orderedBundleIDs
    }

    func repairAppIconData(using iconDataByBundleID: [String: Data]) async -> Int {
        guard iconDataByBundleID.isEmpty == false else { return 0 }
        var total = 0
        var offset = 0
        while !Task.isCancelled {
            let step = repairAppIconDataPage(offset: offset, iconData: iconDataByBundleID)
            total += step.repaired
            if step.isComplete { break }
            offset = step.nextOffset
            await Task.yield()
        }
        return total
    }

    func repairAppIconDataPage(offset: Int, iconData: [String: Data]) -> RepairPageStep {
        guard iconData.isEmpty == false else {
            return RepairPageStep(repaired: 0, nextOffset: offset, isComplete: true)
        }
        do {
            let records = try fetchRecordPage(offset: offset)
            guard records.isEmpty == false else {
                return RepairPageStep(repaired: 0, nextOffset: offset, isComplete: true)
            }
            var repaired = 0
            for record in records {
                guard let bundleID = record.appBundleID,
                      let repairedIconData = iconData[bundleID],
                      record.appIconData != repairedIconData else {
                    continue
                }
                record.appIconData = repairedIconData
                repaired += 1
            }
            if repaired > 0 { try modelContext.save() }
            return RepairPageStep(repaired: repaired, nextOffset: offset + records.count, isComplete: records.count < Self.maintenancePageSize)
        } catch {
            print("❌ [ClipboardStoreActor] 修复 App 图标数据失败: \(error)")
            return RepairPageStep(repaired: 0, nextOffset: offset, isComplete: true)
        }
    }

    static let maintenancePageSize = 64

    func fetchRecordPage(offset: Int) throws -> [ClipboardRecord] {
        var descriptor = FetchDescriptor<ClipboardRecord>(
            sortBy: [SortDescriptor(\.id, order: .forward)]
        )
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = Self.maintenancePageSize
        return try modelContext.fetch(descriptor)
    }
}
