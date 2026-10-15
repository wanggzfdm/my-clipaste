import Foundation
import SwiftData

/// Exact persisted V1 model snapshot; contentHash was not unique in this schema.
enum ClipboardRecordSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ClipboardRecordSchemaV1.ClipboardRecord.self, ClipboardGroupModel.self, SyncAnchor.self]
    }

    @Model
    final class ClipboardRecord {
        var id: UUID = UUID()
        var timestamp: Date = Date()
        var contentHash: String = ""
        var typeRawValue: String = ClipboardContentType.text.rawValue
        var plainText: String?
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
            id: UUID = UUID(), timestamp: Date = Date(), contentHash: String = "",
            typeRawValue: String = ClipboardContentType.text.rawValue, plainText: String? = nil,
            fullTextData: Data? = nil, isPlainTextTruncated: Bool = false,
            previewImageData: Data? = nil, imageData: Data? = nil, imageUTType: String? = nil,
            imageByteCount: Int? = nil, imagePixelWidth: Int? = nil, imagePixelHeight: Int? = nil,
            appBundleID: String? = nil, appLocalizedName: String? = nil,
            appIconDominantColorHex: String? = nil, appIconData: Data? = nil,
            groupId: String? = nil, groupIdsRaw: String? = nil, customTitle: String? = nil,
            linkTitle: String? = nil, linkIconData: Data? = nil, isPinned: Bool = false,
            rtfData: Data? = nil, richTextArchiveData: Data? = nil,
            sourcePlatformRawValue: String = "macOS", sourceDeviceName: String? = nil,
            captureMethodRawValue: String = "monitor", captureSessionID: UUID? = nil
        ) {
            self.id = id; self.timestamp = timestamp; self.contentHash = contentHash
            self.typeRawValue = typeRawValue; self.plainText = plainText; self.fullTextData = fullTextData
            self.isPlainTextTruncated = isPlainTextTruncated; self.previewImageData = previewImageData
            self.imageData = imageData; self.imageUTType = imageUTType; self.imageByteCount = imageByteCount
            self.imagePixelWidth = imagePixelWidth; self.imagePixelHeight = imagePixelHeight
            self.appBundleID = appBundleID; self.appLocalizedName = appLocalizedName
            self.appIconDominantColorHex = appIconDominantColorHex; self.appIconData = appIconData
            self.groupId = groupId; self.groupIdsRaw = groupIdsRaw; self.customTitle = customTitle
            self.linkTitle = linkTitle; self.linkIconData = linkIconData; self.isPinned = isPinned
            self.rtfData = rtfData; self.richTextArchiveData = richTextArchiveData
            self.sourcePlatformRawValue = sourcePlatformRawValue; self.sourceDeviceName = sourceDeviceName
            self.captureMethodRawValue = captureMethodRawValue; self.captureSessionID = captureSessionID
        }
    }
}

enum ClipboardRecordSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [Clipaste.ClipboardRecord.self, ClipboardGroupModel.self, SyncAnchor.self]
    }
}

enum ClipboardRecordMigrationPlan: SchemaMigrationPlan {
    /// Newer timestamps win; ties are resolved by the lexicographically smaller UUID string.
    nonisolated static func migrationWinner(
        _ lhs: ClipboardRecordSchemaV1.ClipboardRecord,
        over rhs: ClipboardRecordSchemaV1.ClipboardRecord
    ) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static var schemas: [any VersionedSchema.Type] { [ClipboardRecordSchemaV1.self, ClipboardRecordSchemaV2.self] }
    static var stages: [MigrationStage] { [deduplicateContentHashes] }

    static let deduplicateContentHashes = MigrationStage.custom(
        fromVersion: ClipboardRecordSchemaV1.self,
        toVersion: ClipboardRecordSchemaV2.self,
        willMigrate: { context in
            let rows = try context.fetch(FetchDescriptor<ClipboardRecordSchemaV1.ClipboardRecord>())
            var seen: [String: ClipboardRecordSchemaV1.ClipboardRecord] = [:]
            for row in rows {
                let hash = row.contentHash.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !hash.isEmpty else {
                    row.contentHash = "legacy-empty-\(row.id.uuidString)"
                    continue
                }
                guard let prior = seen[hash] else {
                    seen[hash] = row
                    row.contentHash = hash
                    continue
                }
                if migrationWinner(row, over: prior) {
                    seen[hash] = row
                    row.contentHash = hash
                    context.delete(prior)
                } else {
                    context.delete(row)
                }
            }
            try context.save()
        }, didMigrate: nil)
}
