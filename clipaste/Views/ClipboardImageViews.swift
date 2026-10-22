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
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            } else {
                placeholder
            }
        }
        .task(id: cacheIdentity) { @MainActor in
            image = await ClipboardImagePipeline.shared.thumbnail(
                for: itemID,
                maxPixelSize: maxPixelSize
            )
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
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            } else {
                placeholder
            }
        }
        .task(id: cacheIdentity) { @MainActor in
            image = await ClipboardImagePipeline.shared.thumbnail(
                forFileURL: fileURL,
                maxPixelSize: maxPixelSize
            )
        }
    }

    private var cacheIdentity: String {
        "\(fileURL.standardizedFileURL.path)-\(maxPixelSize)"
    }
}

struct ClipboardQuickLookImageView: View {
    let itemID: UUID
    var viewModel: ClipboardViewModel

    private var previewFrameSize: CGSize {
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? .zero
        return CGSize(
            width: visibleFrame.width * 0.52,
            height: visibleFrame.height * 0.62
        )
    }

    var body: some View {
        Group {
            if let image = viewModel.highResImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: previewFrameSize.width, height: previewFrameSize.height)
                    .cornerRadius(12)
                    .shadow(color: Color.black.opacity(0.2), radius: 20, x: 0, y: 10)
                    .padding(16)
            } else {
                ClipboardThumbnailView(itemID: itemID, maxPixelSize: 720) {
                    Image(systemName: "photo")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 220, height: 220)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .aspectRatio(contentMode: .fit)
                .frame(width: previewFrameSize.width, height: previewFrameSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(16)
            }
        }
    }
}
