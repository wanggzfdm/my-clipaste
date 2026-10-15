import Foundation

@MainActor
extension ClipboardRuntimeStore {
    func performInitialBootstrap() async {
        do {
            try await bootstrapper.importLegacyStoreIfNeeded(into: currentRuntime.storage)
            let storage = currentRuntime.storage
            Task.detached(priority: .background) {
                let indexer = ClipboardSearchIndexer.shared
                guard await indexer.initialize() else { return }
                await indexer.configureRebuild { limit, offset in
                    await storage.searchIndexEntries(limit: limit, offset: offset)
                }
                await indexer.requestRebuild()
            }
            // 维护任务（文本分类修复、图标颜色/数据修复、去重、超大文本修复）
            // 延迟到面板首次打开后执行，避免冷启动时全表扫描导致内存峰值。
            // 详见 performDeferredMaintenance()。
            NotificationCenter.default.post(name: .clipboardDataDidChange, object: nil)
            scheduleWarmCacheRefresh(using: currentRuntime.storage, routeKey: rootIdentity)
        } catch {
            print("❌ [ClipboardRuntimeStore] Local bootstrap failed: \(error)")
        }
        scheduleMaintenance()
    }

    /// 延迟维护任务：在面板首次打开后后台执行全表扫描修复。
    /// 冷启动时不执行，避免 SwiftData ModelContext 缓存累积导致内存峰值。
    func performDeferredMaintenance() {
        guard hasPerformedDeferredMaintenance == false else { return }
        hasPerformedDeferredMaintenance = true
        deferredMaintenanceTask?.cancel()
        deferredMaintenanceTask = Task { [weak self] in
            guard let self else { return }
            // 延迟 2 秒让面板动画和首屏渲染完成后再开始后台维护
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }

            let storage = self.currentRuntime.storage
            self.scheduleImportedMigrationTimestampRepair(using: storage)
            _ = await self.repairTextClassificationsIfNeeded(using: storage)
            _ = await self.repairAppIconColorsIfNeeded(using: storage)
            _ = await self.repairAppIconDataIfNeeded(using: storage)
            _ = await self.repairDuplicateRecordsIfNeeded(using: storage)
            _ = await self.repairOversizedTextRecordsIfNeeded(using: storage)

            await MainActor.run {
                NotificationCenter.default.post(name: .clipboardDataDidChange, object: nil)
            }
        }
    }
}
