import Foundation
import SwiftData

extension ClipboardStoreActor {
    func searchIndexEntries(limit: Int, offset: Int) -> [ClipboardSearchIndexer.Entry] {
        var descriptor = FetchDescriptor<ClipboardRecord>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        return ((try? modelContext.fetch(descriptor)) ?? []).map {
            ClipboardSearchIndexer.Entry(id: $0.id, plainText: $0.plainText, appName: $0.appLocalizedName, contentHash: $0.contentHash, typeRawValue: $0.typeRawValue, timestamp: $0.timestamp)
        }
    }
    func loadPreviewImageData(id: UUID) -> Data? {
        fetchStoredRecord(id: id)?.previewImageData
    }

    func loadPlainText(id: UUID) -> String? {
        fetchStoredRecord(id: id)?.resolvedPlainText
    }

    func loadAppIconDominantColorHex(id: UUID) -> String? {
        fetchStoredRecord(id: id)?.appIconDominantColorHex
    }

    func loadAppIconData(id: UUID) -> Data? {
        guard let record = fetchStoredRecord(id: id),
              let bundleID = record.appBundleID else { return nil }
        return AppIconManager.shared.iconPNGData(for: bundleID)
    }

    func loadPasteRecord(id: UUID) -> ClipboardPasteRecord? {
        guard let record = fetchStoredRecord(id: id) else {
            return nil
        }

        return ClipboardPasteRecord(
            id: record.id,
            typeRawValue: record.typeRawValue,
            plainText: record.resolvedPlainText,
            rtfData: record.rtfData,
            richTextArchiveData: record.richTextArchiveData
        )
    }

    func loadOriginalImageData(id: UUID) -> Data? {
        fetchStoredRecord(id: id)?.imageData
    }

    func loadImageData(id: UUID) -> Data? {
        if let record = fetchStoredRecord(id: id) {
            return record.imageData ?? record.previewImageData
        }
        return nil
    }

    func loadRTFData(id: UUID) -> Data? {
        fetchStoredRecord(id: id)?.rtfData
    }

    func loadImageUTType(id: UUID) -> String? {
        fetchStoredRecord(id: id)?.imageUTType
    }

    func loadImageDataByHash(hash: String) -> Data? {
        var descriptor = FetchDescriptor<ClipboardRecord>(
            predicate: #Predicate { $0.contentHash == hash }
        )
        descriptor.fetchLimit = 1
        guard let record = try? modelContext.fetch(descriptor).first else { return nil }
        return record.imageData ?? record.previewImageData
    }
}
