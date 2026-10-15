import Foundation
import SwiftData

extension ClipboardStoreActor {
    func upsert(
        hash: String,
        text: String?,
        appID: String?,
        appName: String?,
        appIconDominantColorHex: String?,
        appIconData: Data?,
        type: String,
        rtfData: Data?,
        richTextArchiveData: Data?,
        previewImageData: Data?,
        imageData: Data?,
        imageMetadata: ClipboardImageMetadata?,
        sourcePlatformRawValue: String,
        sourceDeviceName: String?,
        captureMethodRawValue: String,
        captureSessionID: UUID?
    ) async {
        let descriptor = FetchDescriptor<ClipboardRecord>(
            predicate: #Predicate<ClipboardRecord> { record in
                record.contentHash == hash
            }
        )

        do {
            let now = Date()

            let existingRecords = try modelContext.fetch(descriptor)
            let survivorRecord: ClipboardRecord

            if let existingRecord = existingRecords.sorted(by: shouldPreferSurvivor).first {
                existingRecord.timestamp = now
                existingRecord.typeRawValue = type
                existingRecord.appBundleID = appID
                existingRecord.appLocalizedName = appName
                existingRecord.appIconDominantColorHex = appIconDominantColorHex
                // appIconData 不再持久化到每条记录，运行时通过 AppIconManager 从系统获取
                existingRecord.appIconData = nil
                existingRecord.sourcePlatformRawValue = sourcePlatformRawValue
                existingRecord.sourceDeviceName = sourceDeviceName
                existingRecord.captureMethodRawValue = captureMethodRawValue
                existingRecord.captureSessionID = captureSessionID

                if let text {
                    let storedText = ClipboardTextSyncPolicy.storedTextUsingPreferences(for: text)
                    existingRecord.plainText = storedText.inlineText
                    existingRecord.fullTextData = storedText.fullTextData
                    existingRecord.isPlainTextTruncated = storedText.isTruncated
                } else if type != ClipboardContentType.image.rawValue {
                    existingRecord.plainText = nil
                    existingRecord.fullTextData = nil
                    existingRecord.isPlainTextTruncated = false
                }

                refreshStoredTextRepresentations(
                    for: existingRecord,
                    type: type,
                    rtfData: rtfData,
                    richTextArchiveData: richTextArchiveData
                )

                if let previewImageData {
                    existingRecord.previewImageData = previewImageData
                }

                if let imageData {
                    existingRecord.imageData = imageData
                }

                if let imageMetadata {
                    existingRecord.imageUTType = imageMetadata.utTypeIdentifier
                    existingRecord.imageByteCount = imageMetadata.byteCount
                    existingRecord.imagePixelWidth = imageMetadata.pixelWidth
                    existingRecord.imagePixelHeight = imageMetadata.pixelHeight
                }

                for duplicate in existingRecords where duplicate.id != existingRecord.id {
                    merge(duplicate, into: existingRecord)
                    modelContext.delete(duplicate)
                }
                survivorRecord = existingRecord
            } else {
                let storedText = ClipboardTextSyncPolicy.storedTextUsingPreferences(for: text)
                let newRecord = ClipboardRecord(
                    timestamp: now,
                    contentHash: hash,
                    typeRawValue: type,
                    plainText: storedText.inlineText,
                    fullTextData: storedText.fullTextData,
                    isPlainTextTruncated: storedText.isTruncated,
                    previewImageData: previewImageData,
                    imageData: imageData,
                    imageMetadata: imageMetadata,
                    appBundleID: appID,
                    appLocalizedName: appName,
                    appIconDominantColorHex: appIconDominantColorHex,
                    appIconData: nil,
                    rtfData: rtfData,
                    richTextArchiveData: richTextArchiveData,
                    sourcePlatformRawValue: sourcePlatformRawValue,
                    sourceDeviceName: sourceDeviceName,
                    captureMethodRawValue: captureMethodRawValue,
                    captureSessionID: captureSessionID
                )
                modelContext.insert(newRecord)
                survivorRecord = newRecord
            }

            try markSyncAnchorUpdated()
            try modelContext.save()

            // 直接用已有引用构建 FTS Entry，避免保存后重复 fetch
            let entry = ClipboardSearchIndexer.Entry(
                id: survivorRecord.id,
                plainText: survivorRecord.plainText,
                appName: survivorRecord.appLocalizedName,
                contentHash: survivorRecord.contentHash,
                typeRawValue: survivorRecord.typeRawValue,
                timestamp: survivorRecord.timestamp
            )
            let indexed = await ClipboardSearchIndexer.shared.upsert(entry)
            if !indexed {
                print("❌ [ClipboardStoreActor] FTS upsert failed; scheduling rebuild")
                await ClipboardSearchIndexer.shared.requestRebuild()
            }
            NotificationCenter.default.post(
                name: .clipboardRecordDidChange,
                object: nil,
                userInfo: [
                    "contentHash": hash,
                    "kind": ClipboardRecordChangeKind.upsert.rawValue
                ]
            )
        } catch {
            print("❌ [ClipboardStoreActor] 写入失败: \(error)")
        }
    }

    func cleanUpExpiredRecords(before expirationDate: Date) async {
        let batchSize = 200
        do {
            var allExpiredIDs: [UUID] = []
            while true {
                var descriptor = FetchDescriptor<ClipboardRecord>(
                    predicate: #Predicate { $0.timestamp < expirationDate }
                )
                descriptor.fetchLimit = batchSize
                let expiredRecords = try modelContext.fetch(descriptor)
                guard !expiredRecords.isEmpty else { break }

                let expiredIDs = expiredRecords.map(\.id)
                allExpiredIDs.append(contentsOf: expiredIDs)
                for record in expiredRecords {
                    modelContext.delete(record)
                }
                try markSyncAnchorUpdated()
                try modelContext.save()
            }

            guard !allExpiredIDs.isEmpty else { return }

            let indexed = await ClipboardSearchIndexer.shared.delete(ids: allExpiredIDs)
            if !indexed {
                print("❌ [ClipboardStoreActor] FTS delete failed; scheduling rebuild")
                await ClipboardSearchIndexer.shared.requestRebuild()
            }
        } catch {
            print("❌ [清理任务] 清理过期记录失败: \(error)")
        }
    }

    func delete(hash: String) async {
        let descriptor = FetchDescriptor<ClipboardRecord>(
            predicate: #Predicate<ClipboardRecord> { record in
                record.contentHash == hash
            }
        )
        do {
            if let recordToDelete = try modelContext.fetch(descriptor).first {
                modelContext.delete(recordToDelete)
                try markSyncAnchorUpdated()
                try modelContext.save()
                let indexed = await ClipboardSearchIndexer.shared.delete(ids: [recordToDelete.id])
                if !indexed {
                    print("❌ [ClipboardStoreActor] FTS delete failed; scheduling rebuild")
                    await ClipboardSearchIndexer.shared.requestRebuild()
                }
                NotificationCenter.default.post(
                    name: .clipboardRecordDidChange,
                    object: nil,
                    userInfo: [
                        "contentHash": hash,
                        "kind": ClipboardRecordChangeKind.delete.rawValue
                    ]
                )
            }
        } catch {
            print("❌ [ClipboardStoreActor] 删除失败: \(error)")
        }
    }

    func deleteUnpinnedRecords() async {
        let batchSize = 200
        do {
            var allDeletedIDs: [UUID] = []
            while true {
                var descriptor = FetchDescriptor<ClipboardRecord>(
                    predicate: #Predicate<ClipboardRecord> { $0.isPinned == false }
                )
                descriptor.fetchLimit = batchSize
                let records = try modelContext.fetch(descriptor)
                guard !records.isEmpty else { break }

                let deletedIDs = records.map(\.id)
                allDeletedIDs.append(contentsOf: deletedIDs)
                for record in records {
                    modelContext.delete(record)
                }
                try markSyncAnchorUpdated()
                try modelContext.save()
                // 释放本页缓存，避免批量删除时内存累积
            }

            guard !allDeletedIDs.isEmpty else { return }

            let indexed = await ClipboardSearchIndexer.shared.delete(ids: allDeletedIDs)
            if !indexed {
                print("❌ [ClipboardStoreActor] FTS delete failed; scheduling rebuild")
                await ClipboardSearchIndexer.shared.requestRebuild()
            }
            NotificationCenter.default.post(name: .clipboardDataDidChange, object: nil)
        } catch {
            print("❌ [ClipboardStoreActor] 清空失败: \(error)")
        }
    }
}
