import Foundation

@MainActor
extension ClipboardRuntimeStore {
    func scheduleMaintenance() {
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            while !Task.isCancelled {
                while ClipboardPanelManager.shared.isVisible {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled else { return }
                }
                let raw = defaults.string(forKey: "historyRetention") ?? HistoryRetention.oneMonth.rawValue
                if let retention = HistoryRetention(rawValue: raw), let date = retention.expirationDate {
                    StorageManager.shared.performAutoCleanup(before: date)
                }
                try? await Task.sleep(nanoseconds: 24 * 60 * 60 * 1_000_000_000)
            }
        }
    }
}
