import AppKit

final class AppIconManager {
    static let shared = AppIconManager()

    static let syncedIconPixelSize: CGFloat = 128

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        // NSWorkspace 返回的应用图标是多分辨率 NSImage(单个可达数 MB),
        // 必须设置上限,否则随复制来源应用增多缓存只增不减。
        cache.countLimit = 64
        cache.totalCostLimit = 20 * 1024 * 1024 // 20MB
    }

    func getIcon(for bundleIdentifier: String) -> NSImage? {
        guard !bundleIdentifier.isEmpty else { return nil }

        if let cachedImage = cache.object(forKey: bundleIdentifier as NSString) {
            return cachedImage
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let cost = icon.representations.reduce(0) { total, rep in
            total + max(rep.pixelsWide, 1) * max(rep.pixelsHigh, 1) * 4
        }
        cache.setObject(icon, forKey: bundleIdentifier as NSString, cost: cost)
        return icon
    }

    func iconPNGData(for bundleIdentifier: String, pixelSize: CGFloat = syncedIconPixelSize) -> Data? {
        guard let icon = getIcon(for: bundleIdentifier) else { return nil }
        return Self.pngData(from: icon, pixelSize: pixelSize)
    }

    static func pngData(from image: NSImage, pixelSize: CGFloat = syncedIconPixelSize) -> Data? {
        let targetSize = NSSize(width: pixelSize, height: pixelSize)
        let outputImage = NSImage(size: targetSize)

        outputImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        outputImage.unlockFocus()

        guard let tiffData = outputImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }
}
