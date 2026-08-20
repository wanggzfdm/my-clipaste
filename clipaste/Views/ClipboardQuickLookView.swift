import SwiftUI

struct ClipboardQuickLookView: View {
    let item: ClipboardItem
    @ObservedObject var viewModel: ClipboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ClipboardQuickLookToolbar(
                item: item,
                onClose: {
                    viewModel.dismissQuickLook()
                }
            )

            quickLookContent
        }
    }

    @ViewBuilder
    private var quickLookContent: some View {
        if item.contentType == .image {
            ClipboardQuickLookImageView(viewModel: viewModel)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        } else if let parsedColor = item.fastParsedColor {
            // 颜色预览：大色块 + 对比色等宽文字
            ZStack {
                parsedColor
                Text(item.rawText ?? item.textPreview)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundColor(parsedColor.isDark ? .white : .black)
                    .textSelection(.enabled)
            }
            .frame(width: 280, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(10)
        } else {
            ClipboardQuickLookTextContent(
                item: item,
                viewModel: viewModel
            )
        }
    }
}

private struct ClipboardQuickLookToolbar: View {
    let item: ClipboardItem
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close Preview")
            .accessibilityLabel("Close Preview")

            Text(item.typeBadgeTitle())
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

private struct ClipboardQuickLookTextContent: View {
    let item: ClipboardItem
    @ObservedObject var viewModel: ClipboardViewModel

    @State private var highlightedAttr: NSAttributedString?

    private var isCodeContent: Bool {
        item.contentType == .code
    }

    private var safeText: String {
        let fullText = item.rawText ?? item.textPreview
        if fullText.utf8.count > 200_000 {
            return String(fullText.prefix(100_000))
                + "\n\n"
                + String(localized: "Preview truncated to protect memory. Pasting is not affected.")
        }
        return fullText
    }

    private var previewLineCount: Int {
        max(safeText.split(separator: "\n", omittingEmptySubsequences: false).count, 1)
    }

    private var previewMinWidth: CGFloat {
        isCodeContent ? 360 : 400
    }

    private var previewIdealWidth: CGFloat {
        isCodeContent ? 460 : 500
    }

    private var previewMaxWidth: CGFloat {
        700
    }

    private var previewMinHeight: CGFloat {
        isCodeContent ? 96 : 180
    }

    private var previewMaxHeight: CGFloat {
        isCodeContent ? 360 : 600
    }

    private var previewIdealHeight: CGFloat {
        let estimatedLineHeight: CGFloat = isCodeContent ? 20 : 22
        let verticalChrome: CGFloat = isCodeContent ? 42 : 56
        let estimated = CGFloat(min(previewLineCount, 18)) * estimatedLineHeight + verticalChrome
        return min(max(estimated, previewMinHeight), previewMaxHeight)
    }

    private var outerPadding: CGFloat {
        isCodeContent ? 12 : 16
    }

    var body: some View {
        NativeTextView(
            text: safeText,
            attributedText: highlightedAttr,
            style: isCodeContent ? .code : .plain,
            onSelectionChange: { selection in
                viewModel.handleQuickLookTextSelectionChange(selection)
            }
        )
        .frame(
            minWidth: previewMinWidth,
            idealWidth: previewIdealWidth,
            maxWidth: previewMaxWidth,
            minHeight: previewMinHeight,
            idealHeight: previewIdealHeight,
            maxHeight: previewMaxHeight
        )
        .clipShape(RoundedRectangle(cornerRadius: isCodeContent ? 12 : 0, style: .continuous))
        .overlay {
            if isCodeContent {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
        .padding(outerPadding)
        .task(id: item.contentHash) {
            highlightedAttr = await ClipboardQuickLookTextLoader.loadHighlightedText(for: item)
        }
    }
}

@MainActor
private enum ClipboardQuickLookTextLoader {
    private static let rtfDecodeQueue = DispatchQueue(
        label: "clipaste.quicklook-rtf",
        qos: .userInitiated
    )

    static func loadHighlightedText(for item: ClipboardItem) async -> NSAttributedString? {
        guard item.hasRTF else {
            return nil
        }

        let rtfData = await StorageManager.shared.loadRTFData(id: item.id)
        guard let rtfData else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            rtfDecodeQueue.async {
                let attributedText = try? NSAttributedString(
                    data: rtfData,
                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil
                )
                continuation.resume(returning: attributedText)
            }
        }
    }
}
