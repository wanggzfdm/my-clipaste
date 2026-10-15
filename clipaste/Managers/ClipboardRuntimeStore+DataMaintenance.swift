import Foundation

@MainActor
extension ClipboardRuntimeStore {
    func scheduleImportedMigrationTimestampRepair(using storage: StorageManager) {
        guard importedMigrationTimestampRepairTask == nil else { return }
        importedMigrationTimestampRepairTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            _ = await storage.repairImportedMigrationTimestampsInBackground().value
            self?.importedMigrationTimestampRepairTask = nil
        }
    }

    func repairDuplicateRecordsIfNeeded(using storage: StorageManager) async -> Int {
        let currentVersion = DedupThrottle.currentVersion
        guard defaults.integer(forKey: Keys.duplicateRepairVersion) < currentVersion else {
            lastDuplicateRepairDate = Date()
            return 0
        }
        let count = await storage.repairDuplicateRecords()
        defaults.set(currentVersion, forKey: Keys.duplicateRepairVersion)
        lastDuplicateRepairDate = Date()
        return count
    }

    func repairOversizedTextRecordsIfNeeded(using storage: StorageManager) async -> Int {
        let currentVersion = 1
        guard defaults.integer(forKey: Keys.oversizedTextRepairVersion) < currentVersion else { return 0 }
        let count = await storage.repairOversizedInlineTextRecords()
        defaults.set(currentVersion, forKey: Keys.oversizedTextRepairVersion)
        return count
    }

    func repairTextClassificationsIfNeeded(using storage: StorageManager) async -> Int {
        let currentVersion = ClipboardContentClassifier.repairVersion
        guard defaults.integer(forKey: Keys.textClassificationRepairVersion) < currentVersion else { return 0 }
        let count = await storage.repairTextClassificationsIfNeeded()
        defaults.set(currentVersion, forKey: Keys.textClassificationRepairVersion)
        return count
    }

    func repairAppIconColorsIfNeeded(using storage: StorageManager) async -> Int {
        let currentVersion = 1
        guard defaults.integer(forKey: Keys.appIconColorRepairVersion) < currentVersion else { return 0 }
        let bundleIDs = await storage.fetchDistinctAppBundleIDsForColorRepair()
        let colors = Dictionary(uniqueKeysWithValues: bundleIDs.compactMap { id in
            AppIconManager.shared.getIcon(for: id).map { (id, $0.dominantColorHex()) }
        }.compactMap { id, color in color.map { (id, $0) } })
        let count = await storage.repairAppIconDominantColors(using: colors)
        defaults.set(currentVersion, forKey: Keys.appIconColorRepairVersion)
        return count
    }

    func repairAppIconDataIfNeeded(using storage: StorageManager) async -> Int {
        // appIconData 不再持久化到每条记录，跳过修复
        defaults.set(1, forKey: Keys.appIconDataRepairVersion)
        return 0
    }
}
