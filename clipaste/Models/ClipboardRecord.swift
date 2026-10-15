import Foundation
import SwiftData

@Model
final class ClipboardRecord {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    @Attribute(.unique) var contentHash: String = ""
    var typeRawValue: String = ClipboardContentType.text.rawValue
    var plainText: String?
    /// 超大文本的完整 UTF-8 数据，拆分保存以避免内联字段膨胀。
    @Attribute(.externalStorage) var fullTextData: Data?
    var isPlainTextTruncated: Bool = false
    @Attribute(.externalStorage) var previewImageData: Data?
    @Attribute(.externalStorage) var imageData: Data?
    var imageUTType: String?
    var imageByteCount: Int?
    var imagePixelWidth: Int?
    var imagePixelHeight: Int?
    var appBundleID: String?
    var appLocalizedName: String?
    var appIconDominantColorHex: String?
    @Attribute(.externalStorage) var appIconData: Data?
    var groupId: String?
    var groupIdsRaw: String?
    var customTitle: String?
    var linkTitle: String?
    @Attribute(.externalStorage) var linkIconData: Data?
    var isPinned: Bool = false
    @Attribute(.externalStorage) var rtfData: Data?
    @Attribute(.externalStorage) var richTextArchiveData: Data?
    var sourcePlatformRawValue: String = "macOS"
    var sourceDeviceName: String?
    var captureMethodRawValue: String = "monitor"
    var captureSessionID: UUID?

    init(
        id: UUID = UUID(), timestamp: Date = Date(), contentHash: String,
        typeRawValue: String, plainText: String? = nil, fullTextData: Data? = nil,
        isPlainTextTruncated: Bool = false, previewImageData: Data? = nil,
        imageData: Data? = nil, imageMetadata: ClipboardImageMetadata? = nil,
        appBundleID: String? = nil, appLocalizedName: String? = nil,
        appIconDominantColorHex: String? = nil, appIconData: Data? = nil,
        groupId: String? = nil, groupIdsRaw: String? = nil, customTitle: String? = nil,
        linkTitle: String? = nil, linkIconData: Data? = nil, isPinned: Bool = false,
        rtfData: Data? = nil, richTextArchiveData: Data? = nil,
        sourcePlatformRawValue: String = "macOS", sourceDeviceName: String? = nil,
        captureMethodRawValue: String = "monitor", captureSessionID: UUID? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.contentHash = contentHash
        self.typeRawValue = typeRawValue
        self.plainText = plainText
        self.fullTextData = fullTextData
        self.isPlainTextTruncated = isPlainTextTruncated
        self.previewImageData = previewImageData
        self.imageData = imageData
        self.imageUTType = imageMetadata?.utTypeIdentifier
        self.imageByteCount = imageMetadata?.byteCount
        self.imagePixelWidth = imageMetadata?.pixelWidth
        self.imagePixelHeight = imageMetadata?.pixelHeight
        self.appBundleID = appBundleID
        self.appLocalizedName = appLocalizedName
        self.appIconDominantColorHex = appIconDominantColorHex
        self.appIconData = appIconData
        self.groupId = groupId
        self.groupIdsRaw = groupIdsRaw
        self.customTitle = customTitle
        self.linkTitle = linkTitle
        self.linkIconData = linkIconData
        self.isPinned = isPinned
        self.rtfData = rtfData
        self.richTextArchiveData = richTextArchiveData
        self.sourcePlatformRawValue = sourcePlatformRawValue
        self.sourceDeviceName = sourceDeviceName
        self.captureMethodRawValue = captureMethodRawValue
        self.captureSessionID = captureSessionID
    }
}

extension ClipboardRecord {
    /// 完整文本优先取 externalStorage 全文，否则回退到内联预览。
    var resolvedPlainText: String? {
        if let fullTextData, let fullText = String(data: fullTextData, encoding: .utf8) {
            return fullText
        }
        return plainText
    }
}
