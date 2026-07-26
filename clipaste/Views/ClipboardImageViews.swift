import AppKit
import SwiftUI

struct ClipboardThumbnailView<Placeholder: View>: View {
    let itemID: UUID
    let maxPixelSize: Int
    @ViewBuilder let placeholder: Placeholder

    @State private var image: NSImage?

    init(
        itemID: UUID,
        maxPixelSize: Int,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.itemID = itemID
        self.maxPixelSize = maxPixelSize
        self.placeholder = placeholder()
    }

    var body: some View {
        // 缓存命中走同帧渲染,不闪占位符;只有真正的冷加载才异步淡入。
        let resolvedImage = image
            ?? ClipboardImagePipeline.shared.cachedThumbnail(for: itemID, maxPixelSize: maxPixelSize)

        Group {
            if let resolvedImage {
                Image(nsImage: resolvedImage)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            } else {
                placeholder
            }
        }
        .task(id: cacheIdentity) { @MainActor in
            if let cached = ClipboardImagePipeline.shared.cachedThumbnail(for: itemID, maxPixelSize: maxPixelSize) {
                image = cached
                return
            }
            let loaded = await ClipboardImagePipeline.shared.thumbnail(
                for: itemID,
                maxPixelSize: maxPixelSize
            )
            if image == nil, loaded != nil {
                // 占位符 → 图片:淡入;条目切换的旧图替换则直接切,避免二次闪烁。
                withAnimation(.easeIn(duration: 0.2)) {
                    image = loaded
                }
            } else {
                image = loaded
            }
        }
    }

    private var cacheIdentity: String {
        "\(itemID.uuidString)-\(maxPixelSize)"
    }
}

struct ClipboardFileThumbnailView<Placeholder: View>: View {
    let fileURL: URL
    let maxPixelSize: Int
    @ViewBuilder let placeholder: Placeholder

    @State private var image: NSImage?

    init(
        fileURL: URL,
        maxPixelSize: Int,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.fileURL = fileURL
        self.maxPixelSize = maxPixelSize
        self.placeholder = placeholder()
    }

    var body: some View {
        let resolvedImage = image
            ?? ClipboardImagePipeline.shared.cachedThumbnail(forFileURL: fileURL, maxPixelSize: maxPixelSize)

        Group {
            if let resolvedImage {
                Image(nsImage: resolvedImage)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            } else {
                placeholder
            }
        }
        .task(id: cacheIdentity) { @MainActor in
            if let cached = ClipboardImagePipeline.shared.cachedThumbnail(
                forFileURL: fileURL,
                maxPixelSize: maxPixelSize
            ) {
                image = cached
                return
            }
            let loaded = await ClipboardImagePipeline.shared.thumbnail(
                forFileURL: fileURL,
                maxPixelSize: maxPixelSize
            )
            if image == nil, loaded != nil {
                withAnimation(.easeIn(duration: 0.2)) {
                    image = loaded
                }
            } else {
                image = loaded
            }
        }
    }

    private var cacheIdentity: String {
        "\(fileURL.standardizedFileURL.path)-\(maxPixelSize)"
    }
}

struct ClipboardQuickLookImageView: View {
    @ObservedObject var viewModel: ClipboardViewModel

    var body: some View {
        Group {
            if let image = viewModel.highResImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        width: viewModel.previewTargetSize.width,
                        height: viewModel.previewTargetSize.height
                    )
                    .cornerRadius(12)
                    .shadow(color: Color.black.opacity(0.2), radius: 20, x: 0, y: 10)
                    .padding(16)
            } else {
                ProgressView()
                    .frame(width: 220, height: 220)
                    .padding(16)
            }
        }
    }
}
