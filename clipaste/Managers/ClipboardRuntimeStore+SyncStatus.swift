import Foundation

@MainActor
extension ClipboardRuntimeStore {
    func setSyncEnabled(_ enabled: Bool) { defaults.set(false, forKey: "enable_icloud_sync") }
    func refreshCurrentRoute() {}
    func resetCloudLocalCache() {}
}
