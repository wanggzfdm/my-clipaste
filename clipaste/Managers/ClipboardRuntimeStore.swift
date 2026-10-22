import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class ClipboardRuntimeStore {
    static let shared = ClipboardRuntimeStore()

    var container: ModelContainer { currentRuntime.container }
    var isSyncEnabled: Bool { false }
    var runtimeGeneration: UUID
    let defaults: UserDefaults
    let containerFactory: ClipboardModelContainerFactory
    let bootstrapper: ClipboardStoreBootstrapper
    var currentRuntime: ClipboardRuntime
    var maintenanceTask: Task<Void, Never>?
    var importedMigrationTimestampRepairTask: Task<Void, Never>?
    var clipboardSnapshotSignature: String?
    var lastDuplicateRepairDate: Date?
    var hasPerformedDeferredMaintenance = false
    var deferredMaintenanceTask: Task<Void, Never>?
    nonisolated(unsafe) private var memoryPressureSource: DispatchSourceMemoryPressure?

    var localRuntime: ClipboardRuntime { currentRuntime }
    var syncError: String? { nil }
    var isSyncing: Bool { false }
    var lastSyncDate: Date? { nil }

    var clipboardStore: StorageManager { currentRuntime.storage }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        containerFactory = .shared
        bootstrapper = ClipboardStoreBootstrapper()
        let runtimeResolution: ClipboardRuntimeBootstrapResolution<ClipboardRuntime>
        do {
            runtimeResolution = try ClipboardRuntimeBootstrapPolicy.resolve(
                preferredSyncEnabled: false,
                makePersistentRuntime: { _ in try ClipboardModelContainerFactory.shared.makeRuntime() },
                makeInMemoryRuntime: { try ClipboardModelContainerFactory.shared.makeInMemoryRuntime() }
            )
        } catch {
            preconditionFailure("Unable to initialize clipboard runtime: \(error.localizedDescription)")
        }
        currentRuntime = runtimeResolution.value
        if runtimeResolution.source == .memoryFallback {
            print("⚠️ Clipboard storage recovery mode: \(runtimeResolution.preferredError?.localizedDescription ?? "unknown persistent-store error")")
        }
        runtimeGeneration = UUID()
        defaults.set(false, forKey: "enable_icloud_sync")
        ClipboardStorageRegistry.update(storage: currentRuntime.storage)
        scheduleWarmCacheRefresh(using: currentRuntime.storage, routeKey: rootIdentity)
        ClipboardMonitor.shared.startMonitoring()
        setupMemoryPressureHandling()
        Task { await performInitialBootstrap() }
    }

    private func setupMemoryPressureHandling() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                print("⚠️ [ClipboardRuntimeStore] 内存压力通知触发，清理缓存")
                ClipboardImagePipeline.shared.invalidateAll()
                Task { await ClipboardHistoryWarmCache.shared.clear() }
            }
        }
        source.activate()
        memoryPressureSource = source
    }
}
