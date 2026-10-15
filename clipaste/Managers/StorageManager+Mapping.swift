import Foundation
import SwiftData

extension StorageManager {
    nonisolated static func makeClipboardItem(from record: ClipboardRecordSnapshot) -> ClipboardItem {
        let type = ClipboardContentType(rawValue: record.typeRawValue) ?? .text

        // 列表展示只保留截断文本，完整文本在粘贴/QuickLook 时按需从数据库加载
        let truncatedText = Self.truncateForListDisplay(record.plainText, type: type) ?? ""

        return ClipboardItem(
            id: record.id,
            contentType: type,
            contentHash: record.contentHash,
            textPreview: truncatedText,
            searchableText: ClipboardItem.searchableTextValue(
                plainText: truncatedText,
                customTitle: record.customTitle,
                linkTitle: record.linkTitle
            ),
            sourceBundleIdentifier: record.bundleIdentifier,
            appName: record.appName,
            appIcon: nil,
            appIconName: ClipboardItem.appIconName(for: record.bundleIdentifier),
            appIconDominantColorHex: record.appIconDominantColorHex,
            timestamp: record.timestamp,
            rawText: nil,
            hasImagePreview: record.hasPreviewImage,
            hasImageData: record.hasImageData,
            imageUTType: record.imageUTType,
            imagePixelWidth: record.imagePixelWidth,
            imagePixelHeight: record.imagePixelHeight,
            fileURL: type == .fileURL ? record.plainText : nil,
            groupId: record.groupId,
            groupIDs: normalizedGroupIDs(primaryGroupID: record.groupId, groupIdsRaw: record.groupIdsRaw),
            customTitle: record.customTitle,
            linkTitle: record.linkTitle,
            linkIconData: record.linkIconData,
            isPinned: record.isPinned,
            hasRTF: record.hasRTF,
            sourcePlatformRawValue: record.sourcePlatformRawValue,
            sourceDeviceName: record.sourceDeviceName,
            captureMethodRawValue: record.captureMethodRawValue,
            captureSessionID: record.captureSessionID
        )
    }

    /// 列表展示用的文本截断：text/link/code 类型截断为前 2000 字符，
    /// 避免大文本常驻内存。完整文本通过 loadPlainText(id:) 按需加载。
    fileprivate nonisolated static func truncateForListDisplay(_ plainText: String?, type: ClipboardContentType) -> String? {
        guard let plainText else { return nil }
        let limit = 2000
        if plainText.count <= limit { return plainText }
        return String(plainText.prefix(limit))
    }

    fileprivate nonisolated static func makeTextPreview(plainText: String?, type: ClipboardContentType) -> String {
        switch type {
        case .text, .link, .code:
            return plainText ?? ""
        case .fileURL:
            guard
                let plainText,
                let url = URL(string: plainText),
                url.isFileURL,
                !url.lastPathComponent.isEmpty
            else {
                return plainText ?? "File"
            }

            return url.lastPathComponent
        case .image:
            return "Image"
        case .color:
            return plainText ?? "Color"
        }
    }
}
