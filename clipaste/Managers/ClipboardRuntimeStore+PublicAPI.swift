import Foundation

@MainActor
extension ClipboardRuntimeStore {
    var storage: StorageManager { currentRuntime.storage }
    var rootIdentity: String { "local-\(runtimeGeneration.uuidString)" }

    func handleAppBecameActive() { scheduleWarmCacheRefresh(using: storage, routeKey: rootIdentity) }

    func scheduleWarmCacheRefresh(using storage: StorageManager, routeKey: String) {
        Task.detached(priority: .background) {
            let items = await storage.fetchItemsPage(searchText: "", fetchLimit: ClipboardHistoryWarmCache.defaultLimit, offset: 0)
            await ClipboardHistoryWarmCache.shared.update(items: items, routeKey: routeKey)
            await MainActor.run {
                NotificationCenter.default.post(name: .clipboardWarmCacheDidChange, object: nil, userInfo: ["routeKey": routeKey])
            }
        }
    }
}
