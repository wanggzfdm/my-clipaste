import AppKit
import Foundation

@MainActor
final class ClipboardImagePipeline {
    static let shared = ClipboardImagePipeline()

    private static let thumbnailQueue = DispatchQueue(
        label: "clipaste.thumbnail-pipeline",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private let cache = NSCache<NSString, NSImage>()
    private let memoryCache = NSCache<NSString, NSImage>()
    
    private let imageLoadingQueue = DispatchQueue(
        label: "clipaste.image-loading",
        qos: .userInitiated,
        attributes: .concurrent
    )
    
    private var loadingTasks: [String: Task<NSImage?, Never>] = [:]

    private init() {
        cache.countLimit = 512
        cache.totalCostLimit = 100 * 1024 * 1024 // 100MB
        
        memoryCache.countLimit = 128
        memoryCache.totalCostLimit = 50 * 1024 * 1024 // 50MB
    }

    func invalidateAll() {
        cache.removeAllObjects()
        memoryCache.removeAllObjects()
        loadingTasks.values.forEach { $0.cancel() }
        loadingTasks.removeAll()
    }
    
    private func loadWithDeduplication(
        cacheKey: String,
        loadTask: @escaping () async -> NSImage?
    ) async -> NSImage? {
        // 检查内存缓存
        if let cached = memoryCache.object(forKey: cacheKey as NSString) {
            return cached
        }
        
        // 检查是否已有加载任务
        if let existingTask = loadingTasks[cacheKey] {
            return await existingTask.value
        }
        
        // 创建新的加载任务
        let task = Task { await loadTask() }
        loadingTasks[cacheKey] = task
        
        defer {
            imageLoadingQueue.async { [weak self] in
                self?.loadingTasks[cacheKey] = nil
            }
        }
        
        let image = await task.value
        
        if let image {
            cache.setObject(image, forKey: cacheKey as NSString)
            memoryCache.setObject(image, forKey: cacheKey as NSString)
        }
        
        return image
    }

    func thumbnail(for itemID: UUID, maxPixelSize: Int) async -> NSImage? {
        let cacheKey = "thumb-\(itemID.uuidString)-\(maxPixelSize)"
        
        return await loadWithDeduplication(cacheKey: cacheKey) { [weak self] in
            guard let self = self else { return nil }
            
            let data: Data
            if let previewData = await StorageManager.shared.loadPreviewImageData(id: itemID) {
                data = previewData
            } else if let fallbackData = await StorageManager.shared.loadImageData(id: itemID) {
                data = fallbackData
            } else {
                return nil
            }

            return await Self.downsampleImageOffMain(data, maxPixelSize: maxPixelSize)
        }
    }

    func quickLookPreviewImage(for itemID: UUID, maxPixelSize: Int) async -> NSImage? {
        let cacheKey = "ql-preview-\(itemID.uuidString)-\(maxPixelSize)"
        
        return await loadWithDeduplication(cacheKey: cacheKey) { [weak self] in
            guard let self = self else { return nil }
            
            let data: Data
            if let previewData = await StorageManager.shared.loadPreviewImageData(id: itemID) {
                data = previewData
            } else if let fallbackData = await StorageManager.shared.loadOriginalImageData(id: itemID) {
                data = fallbackData
            } else if let imageData = await StorageManager.shared.loadImageData(id: itemID) {
                data = imageData
            } else {
                return nil
            }

            return await Self.downsampleImageOffMain(data, maxPixelSize: maxPixelSize)
        }
    }

    func previewImage(for itemID: UUID, maxPixelSize: Int) async -> NSImage? {
        let cacheKey = "preview-\(itemID.uuidString)-\(maxPixelSize)"
        
        return await loadWithDeduplication(cacheKey: cacheKey) { [weak self] in
            guard let self = self else { return nil }
            
            let data: Data
            if let originalData = await StorageManager.shared.loadOriginalImageData(id: itemID) {
                data = originalData
            } else if let previewData = await StorageManager.shared.loadPreviewImageData(id: itemID) {
                data = previewData
            } else if let fallbackData = await StorageManager.shared.loadImageData(id: itemID) {
                data = fallbackData
            } else {
                return nil
            }

            return await Self.downsampleImageOffMain(data, maxPixelSize: maxPixelSize)
        }
    }

    func thumbnail(forFileURL fileURL: URL, maxPixelSize: Int) async -> NSImage? {
        let cacheKey = "file-thumb-\(fileURL.standardizedFileURL.path)-\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        let image = await Self.loadAndDownsampleFileImageOffMain(
            fileURL: fileURL,
            maxPixelSize: maxPixelSize
        )

        if let image {
            cache.setObject(image, forKey: cacheKey)
        }

        return image
    }

    private static func downsampleImageOffMain(_ data: Data, maxPixelSize: Int) async -> NSImage? {
        await withCheckedContinuation { continuation in
            thumbnailQueue.async {
                let image = ImageProcessor.downsampleImage(from: data, maxPixelSize: maxPixelSize)
                continuation.resume(returning: image)
            }
        }
    }

    private static func loadAndDownsampleFileImageOffMain(fileURL: URL, maxPixelSize: Int) async -> NSImage? {
        await withCheckedContinuation { continuation in
            thumbnailQueue.async {
                guard let data = ClipboardFileReference.loadImageData(from: fileURL) else {
                    continuation.resume(returning: nil)
                    return
                }

                let image = ImageProcessor.downsampleImage(from: data, maxPixelSize: maxPixelSize)
                continuation.resume(returning: image)
            }
        }
    }
}
