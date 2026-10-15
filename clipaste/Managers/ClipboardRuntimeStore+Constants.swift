import Foundation

extension ClipboardRuntimeStore {
    enum Keys {
        static let syncEnabled = "enable_icloud_sync"
        static let textClassificationRepairVersion = "clipboard_text_classification_repair_version"
        static let appIconColorRepairVersion = "clipboard_app_icon_color_repair_version"
        static let appIconDataRepairVersion = "clipboard_app_icon_data_repair_version"
        static let duplicateRepairVersion = "clipboard_duplicate_repair_version"
        static let oversizedTextRepairVersion = "clipboard_oversized_text_repair_version"
    }

    enum DedupThrottle {
        static let minimumInterval: TimeInterval = 10 * 60
        static let currentVersion = 1
    }
}
