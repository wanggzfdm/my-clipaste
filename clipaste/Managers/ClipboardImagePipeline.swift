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

    /// 单一缓存:读写路径一致,配合真实 cost 让 totalCostLimit 生效。
    /// (旧实现的 cache/memoryCache 双缓存互相持有同一 NSImage,淘汰互相失效。)
    private let cache = NSCache<NSString, NSImage>()

    private var loadingTasks: [String: Task<NSImage?, Never>] = [:]

    private init() {
        cache.countLimit = 256
        cache.totalCostLimit = 64 * 1024 * 1024 // 64MB,按位图字节估算 cost
    }

    func invalidateAll() {
        cache.removeAllObjects()
        loadingTasks.values.forEach { $0.cancel() }
        loadingTasks.removeAll()
    }

    /// NSCache 的 totalCostLimit 只统计 setObject 时传入的 cost;
    /// 不传 cost 时条目按 0 计,容量上限形同虚设。
    private static func estimatedCost(of image: NSImage) -> Int {
        let representationBytes = image.representations.reduce(0) { total, rep in
            total + max(rep.pixelsWide, 1) * max(rep.pixelsHigh, 1) * 4
        }
        if representationBytes > 0 {
            return representationBytes
        }
        return Int(max(image.size.width, 1) * max(image.size.height, 1) * 4)
    }

    private func store(_ image: NSImage, forKey cacheKey: String) {
        cache.setObject(image, forKey: cacheKey as NSString, cost: Self.estimatedCost(of: image))
    }

    private func loadWithDeduplication(
        cacheKey: String,
        loadTask: @escaping () async -> NSImage?
    ) async -> NSImage? {
        if let cached = cache.object(forKey: cacheKey as NSString) {
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
            loadingTasks[cacheKey] = nil
        }

        let image = await task.value

        if let image {
            store(image, forKey: cacheKey)
        }

        return image
    }

    private static func thumbnailCacheKey(for itemID: UUID, maxPixelSize: Int) -> String {
        "thumb-\(itemID.uuidString)-\(maxPixelSize)"
    }

    private static func fileThumbnailCacheKey(for fileURL: URL, maxPixelSize: Int) -> String {
        "file-thumb-\(fileURL.standardizedFileURL.path)-\(maxPixelSize)"
    }

    private static func linkIconCacheKey(for itemID: UUID) -> String {
        "link-icon-\(itemID.uuidString)"
    }

    /// 同步缓存命中查询:视图 body 里先取缓存可同帧渲染,避免占位符闪烁。
    func cachedThumbnail(for itemID: UUID, maxPixelSize: Int) -> NSImage? {
        cache.object(forKey: Self.thumbnailCacheKey(for: itemID, maxPixelSize: maxPixelSize) as NSString)
    }

    func cachedThumbnail(forFileURL fileURL: URL, maxPixelSize: Int) -> NSImage? {
        cache.object(forKey: Self.fileThumbnailCacheKey(for: fileURL, maxPixelSize: maxPixelSize) as NSString)
    }

    func cachedLinkIcon(for itemID: UUID) -> NSImage? {
        cache.object(forKey: Self.linkIconCacheKey(for: itemID) as NSString)
    }

    func thumbnail(for itemID: UUID, maxPixelSize: Int) async -> NSImage? {
        let cacheKey = Self.thumbnailCacheKey(for: itemID, maxPixelSize: maxPixelSize)

        return await loadWithDeduplication(cacheKey: cacheKey) {
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

        return await loadWithDeduplication(cacheKey: cacheKey) {
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

        return await loadWithDeduplication(cacheKey: cacheKey) {
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
        let cacheKey = Self.fileThumbnailCacheKey(for: fileURL, maxPixelSize: maxPixelSize)

        return await loadWithDeduplication(cacheKey: cacheKey) {
            await Self.loadAndDownsampleFileImageOffMain(
                fileURL: fileURL,
                maxPixelSize: maxPixelSize
            )
        }
    }

    /// 链接卡片 favicon:列表数据只带 hasLinkIcon 标志,二进制在这里按需读库、
    /// 后台解码并缓存,避免数百条链接的图标随 items 常驻内存。
    func linkIcon(for itemID: UUID) async -> NSImage? {
        let cacheKey = Self.linkIconCacheKey(for: itemID)

        return await loadWithDeduplication(cacheKey: cacheKey) {
            guard let data = await StorageManager.shared.loadLinkIconData(id: itemID) else {
                return nil
            }
            return await Self.decodeImageOffMain(data)
        }
    }

    private static func decodeImageOffMain(_ data: Data) async -> NSImage? {
        await withCheckedContinuation { continuation in
            thumbnailQueue.async {
                continuation.resume(returning: NSImage(data: data))
            }
        }
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
