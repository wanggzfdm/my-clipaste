import AppKit
import SwiftUI

struct ClipboardCardView: View {
    let item: ClipboardItem
    @ObservedObject var viewModel: ClipboardViewModel
    var quickPasteIndex: Int? = nil
    
    @Environment(\.shouldDisableAnimations) private var shouldDisableAnimations
    @Environment(\.colorScheme) private var colorScheme

    @State private var isHovered = false
    @State private var richPreviewText: AttributedString?
    @AppStorage("appAccentColor") private var appAccentColor: AppAccentColor = .defaultValue

    private var isSelected: Bool {
        viewModel.selectedItemIDs.contains(item.id)
    }

    private var previewText: String {
        if let preview = item.previewText, !preview.isEmpty { return preview }
        return item.textPreview.isEmpty ? String(localized: "(Empty)") : item.textPreview
    }

    private var searchHighlight: String { viewModel.activeSearchQuery }

    private var quickPasteNumber: Int? {
        quickPasteIndex.map { $0 + 1 }
    }

    private var showsQuickPasteBadge: Bool {
        quickPasteNumber != nil && viewModel.isQuickPasteModifierHeld
    }

    private var shouldTriggerPreview: Bool {
        false
    }

    private var richTextTaskKey: String {
        "\(item.id.uuidString)-\(item.contentHash)-\(item.hasRTF)-search:\(viewModel.isSearchFilteringActive)"
    }

    private var headerTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.96) : Color.primary.opacity(0.88)
    }

    private var headerTimestampText: String {
        "\(item.timestamp.dateString) \(item.timestamp.timeString)"
    }

    private var timestampHelpText: String {
        item.timestamp.formatted(
            .dateTime
                .locale(Locale(identifier: "zh-Hans"))
                .year()
                .month(.wide)
                .day()
                .weekday(.wide)
                .hour()
                .minute()
                .second()
        )
    }

    private var headerHeight: CGFloat {
        54
    }

    private enum Layout {
        static let baseCardSize: CGFloat = 252
        static let cardScale: CGFloat = 0.98
        static let cardSize = baseCardSize * cardScale
    }

    private var cardCornerRadius: CGFloat {
        25
    }

    private var sourceAccentColor: Color {
        ClipboardCardSourcePalette.color(
            storedHex: item.appIconDominantColorHex,
            image: resolvedAppIcon,
            fallback: appAccentColor.color
        )
    }

    private var cardSurfaceColor: Color {
        (colorScheme == .dark ? Color.black : Color(nsColor: .windowBackgroundColor))
            .opacity(colorScheme == .dark ? 0.78 : 0.58)
    }

    private var headerSurfaceColor: Color {
        if colorScheme == .dark {
            return sourceAccentColor.opacity(0.98)
        }

        return sourceAccentColor.opacity(0.96)
    }

    private var headerHighlightColor: Color {
        Color.white.opacity(colorScheme == .dark ? 0.08 : 0.12)
    }

    private var headerDepthColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.04 : 0.035)
    }

    private var primaryContentTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.94) : Color.primary.opacity(0.9)
    }

    private var cardBorderColor: Color {
        isSelected
            ? sourceAccentColor.opacity(0.72)
            : Color.primary.opacity(colorScheme == .dark ? (isHovered ? 0.16 : 0.08) : (isHovered ? 0.14 : 0.07))
    }

    private var cardShadowColor: Color {
        isSelected
            ? sourceAccentColor.opacity(colorScheme == .dark ? 0.18 : 0.12)
            : Color.black.opacity(colorScheme == .dark ? 0.24 : 0.11)
    }

    private var resolvedAppIcon: NSImage? {
        if let icon = item.appIcon {
            return icon
        }

        guard let bundleIdentifier = item.sourceBundleIdentifier else {
            return nil
        }

        return AppIconManager.shared.getIcon(for: bundleIdentifier)
    }

    // MARK: - Body
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader

            contentBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 13)
                .padding(.top, 8)
                .padding(.bottom, 13)
        }
        .frame(width: Layout.cardSize, height: Layout.cardSize)
        .background {
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)

                cardSurfaceColor

                if isSelected {
                    sourceAccentColor.opacity(colorScheme == .dark ? 0.08 : 0.06)
                }

                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.035 : 0.22),
                        Color.white.opacity(colorScheme == .dark ? 0.012 : 0.09),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .stroke(
                    cardBorderColor,
                    lineWidth: isSelected ? 1.5 : 0.8
                )
        }
        .clipShape(.rect(cornerRadius: cardCornerRadius, style: .continuous))
        .shadow(color: cardShadowColor, radius: isSelected ? 14 : 9, x: 0, y: 5)
        .animation(nil, value: showsQuickPasteBadge)
        .background {
            if let quickPasteIndex {
                QuickPasteShortcutHost(
                    shortcutIndex: quickPasteIndex,
                    modifierKey: viewModel.quickPasteModifier
                ) {
                    viewModel.pasteToActiveApp(item: item)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            bottomAccessory
        }
        // 分享锚点：用 background 捕获 NSView + onChange 触发分享
        .modifier(OptionalShareModifier(item: item, viewModel: viewModel))
        .task(id: richTextTaskKey) {
            await refreshRichPreviewText()
        }
        .clipboardContextMenu(for: item, viewModel: viewModel)
        .onHover { hovering in
            if shouldDisableAnimations {
                isHovered = hovering
            } else {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9, blendDuration: 0.1)) {
                    isHovered = hovering
                }
            }

        }
        .onDrag {
            viewModel.draggedItemId = item.id
            return item.universalDragProvider
        } preview: {
            ClipboardDragPreview(item: item)
        }
        .modifier(ClipboardCardActionModifier(item: item, viewModel: viewModel))
    }

    private var cardHeader: some View {
        ZStack(alignment: .topTrailing) {
            HStack(alignment: .center, spacing: 8) {
                Text(item.typeBadgeTitle())
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(headerTextColor)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text(headerTimestampText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(headerTextColor.opacity(0.76))
                    .lineLimit(1)
            }
            .padding(.leading, 14)
            .padding(.trailing, 64)
            .frame(height: headerHeight)
            .background {
                ZStack {
                    headerSurfaceColor

                    LinearGradient(
                        colors: [
                            headerHighlightColor,
                            sourceAccentColor.opacity(colorScheme == .dark ? 0.10 : 0.08),
                            headerDepthColor
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
            .help(timestampHelpText)

            AppIconView(appBundleID: item.sourceBundleIdentifier, size: 50)
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.22), lineWidth: 0.8)
                }
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.14 : 0.10), radius: 4, x: 0, y: 1)
                .padding(.top, 6)
                .padding(.trailing, 10)
        }
        .frame(height: headerHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(colorScheme == .dark ? 0.10 : 0.08))
                .frame(height: 0.5)
        }
        .overlay(alignment: .leading) {
            headerCustomTitleOverlay
        }
    }

    @ViewBuilder
    private var bottomAccessory: some View {
        if let quickPasteNumber, showsQuickPasteBadge {
            QuickPasteShortcutBadge(
                modifierKey: viewModel.quickPasteModifier,
                number: quickPasteNumber,
                color: .secondary
            )
            .padding(.trailing, 12)
            .padding(.bottom, 12)
            .transition(.opacity)
        } else if showsAIShortcut {
            ClipboardAIActionMenu(item: item, viewModel: viewModel) {
                HStack(spacing: -4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9, weight: .medium))

                    Text("AI")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Color(nsColor: .systemGray))
                .padding(.horizontal, 4)
                .frame(height: 22)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.black.opacity(0.10), lineWidth: 0.5)
                }
                .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1)
                .contentShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("AI 功能"))
            .padding(.trailing, 12)
            .padding(.bottom, 12)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }

    // MARK: - Content Body

    @ViewBuilder
    private var contentBody: some View {
        if item.contentType == .fileURL, let fileURL = item.resolvedFileURL {
            let displayPath = item.fileDisplayPath ?? fileURL.path

            if item.fileRepresentsImage {
                ZStack {
                    CheckerboardBackground()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    ClipboardFileThumbnailView(fileURL: fileURL, maxPixelSize: 480) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: displayPath))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 64, height: 64)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // ── 文件类型：系统原生图标 + 文件名 + 路径 ──────────────────
                VStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: displayPath))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)
                    VStack(spacing: 2) {
                        Text(item.fileDisplayName ?? (displayPath as NSString).lastPathComponent)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .multilineTextAlignment(.center)
                        Text(displayPath)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if item.contentType == .image {
            // ── 图片：等比例完整显示，绝不裁切原图 ──────────────────────
            ZStack {
                CheckerboardBackground()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                ClipboardThumbnailView(itemID: item.id, maxPixelSize: 480) {
                    Group {
                        if item.hasImagePreview || item.hasImageData {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.secondary)
                        } else {
                            Image(systemName: "photo")
                                .font(.title2)
                                .foregroundStyle(.secondary.opacity(0.8))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let parsedColor = item.fastParsedColor {
            // ── 颜色块：全卡片沉浸式填充 ──────────────────────────────────
            ZStack {
                parsedColor
                Text(previewText)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(parsedColor.isDark ? .white : .black)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if item.isFastLink {
            switch viewModel.settingsViewModel.linkDisplayMode {
            case .rich:
                ClipboardLinkPreviewCardView(
                    viewModel: ClipboardLinkPreviewViewModel(item: item),
                    highlight: searchHighlight
                )
            case .plain:
                ClipboardLinkPlainCardView(
                    viewModel: ClipboardLinkPreviewViewModel(item: item),
                    highlight: searchHighlight
                )
            }
        } else {
            // ── 普通文本（含代码）：▄▀ ListRenderEngine 缓存优先
            if let richPreviewText {
                Text(richPreviewText)
                    .foregroundStyle(primaryContentTextColor)
                    .lineSpacing(3)
                    .lineLimit(10)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                HighlightedText(
                    text: previewText,
                    highlight: searchHighlight,
                    font: .system(size: 13, design: isCodeContent ? .monospaced : .default),
                    foregroundColor: primaryContentTextColor,
                    highlightFont: .system(size: 13, weight: .bold, design: isCodeContent ? .monospaced : .default)
                )
                .lineSpacing(3)
                .lineLimit(10)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: - Helpers

    private var isCodeContent: Bool {
        item.contentType == .code
    }

    private var showsAIShortcut: Bool {
        viewModel.aiSettingsViewModel.isAIEnabled
            && (isHovered || isSelected)
            && viewModel.isQuickPasteModifierHeld == false
    }

    @ViewBuilder
    private var headerCustomTitleOverlay: some View {
        if item.hasCustomTitle {
            VStack {
                Spacer(minLength: 0)

                ClipboardItemCustomTitleView(
                    item: item,
                    viewModel: viewModel,
                    font: .system(size: 11, weight: .semibold),
                    textColor: headerTextColor.opacity(0.96)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 12)
            .padding(.trailing, 56)
            .padding(.bottom, 8)
        }
    }

    @MainActor
    private func refreshRichPreviewText() async {
        guard viewModel.isSearchFilteringActive == false else {
            richPreviewText = nil
            return
        }

        richPreviewText = ListRenderEngine.shared.cachedText(for: item.id)

        guard richPreviewText == nil else {
            return
        }

        try? await Task.sleep(nanoseconds: 90_000_000)
        guard !Task.isCancelled else {
            return
        }

        richPreviewText = await ListRenderEngine.shared.prepareText(for: item)
    }
}

// MARK: - Checkerboard Background (for transparent images)

/// 经典灰白棋盘格 — 透明图片可视化底色
private struct CheckerboardBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    let cellSize: CGFloat = 8

    private var lightColor: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(calibratedWhite: 0.16, alpha: 0.85))
            : Color.white.opacity(0.8)
    }

    private var darkColor: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(calibratedWhite: 0.09, alpha: 0.90))
            : Color.gray.opacity(0.15)
    }

    var body: some View {
        Canvas { context, size in
            let cols = Int(ceil(size.width / cellSize))
            let rows = Int(ceil(size.height / cellSize))
            for row in 0..<rows {
                for col in 0..<cols {
                    let isEven = (row + col) % 2 == 0
                    let rect = CGRect(x: CGFloat(col) * cellSize,
                                      y: CGFloat(row) * cellSize,
                                      width: cellSize, height: cellSize)
                    context.fill(Path(rect), with: .color(isEven ? lightColor : darkColor))
                }
            }
        }
    }
}

private enum ClipboardCardSourcePalette {
    private static let cache = NSCache<NSString, NSColor>()
    private static let paletteVersion = "paste-palette-v3"

    static func color(storedHex: String?, image: NSImage?, fallback: Color) -> Color {
        let sourceKey = storedHex ?? image.map { String(ObjectIdentifier($0).hashValue) } ?? "fallback"
        let cacheKey = "\(paletteVersion)-\(sourceKey)"

        if let cached = cache.object(forKey: cacheKey as NSString) {
            return Color(nsColor: cached)
        }

        guard let nsColor = resolvedColor(storedHex: storedHex, image: image) else {
            return fallback
        }

        cache.setObject(nsColor, forKey: cacheKey as NSString)
        return Color(nsColor: nsColor)
    }

    private static func resolvedColor(storedHex: String?, image: NSImage?) -> NSColor? {
        if let color = storedHex.flatMap(parseHexColor(_:)) {
            return normalizedHeaderColor(from: color)
        }

        guard let image,
              let extractedHex = image.dominantColorHex(),
              let color = parseHexColor(extractedHex) else {
            return nil
        }

        return normalizedHeaderColor(from: color)
    }

    private static func parseHexColor(_ hex: String) -> NSColor? {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines))
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else {
            return nil
        }

        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func normalizedHeaderColor(from color: NSColor) -> NSColor {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        srgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        if saturation < 0.12 {
            let gray = min(max(brightness, 0.52), 0.62)
            return NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)
        }

        let target = targetHSB(forHue: hue, saturation: saturation, brightness: brightness)
        return NSColor(
            hue: hue,
            saturation: target.saturation,
            brightness: target.brightness,
            alpha: 1
        )
    }

    private static func targetHSB(
        forHue hue: CGFloat,
        saturation originalSaturation: CGFloat,
        brightness originalBrightness: CGFloat
    ) -> (saturation: CGFloat, brightness: CGFloat) {
        let isGreen = (0.24...0.45).contains(hue)
        let isCyanBlue = (0.46...0.64).contains(hue)
        let isPurple = (0.65...0.80).contains(hue)
        let isRedOrOrange = hue >= 0.94 || hue <= 0.12

        let saturationRange: ClosedRange<CGFloat>
        let brightnessRange: ClosedRange<CGFloat>

        switch true {
        case isGreen:
            saturationRange = 0.82...0.94
            brightnessRange = 0.76...0.86
        case isCyanBlue:
            saturationRange = 0.78...0.90
            brightnessRange = 0.82...0.92
        case isPurple:
            saturationRange = 0.64...0.78
            brightnessRange = 0.72...0.84
        case isRedOrOrange:
            saturationRange = 0.72...0.86
            brightnessRange = 0.80...0.90
        default:
            saturationRange = 0.68...0.84
            brightnessRange = 0.76...0.88
        }

        return (
            saturation: min(max(originalSaturation, saturationRange.lowerBound), saturationRange.upperBound),
            brightness: min(max(originalBrightness, brightnessRange.lowerBound), brightnessRange.upperBound)
        )
    }
}

#Preview {
    ClipboardCardView(
        item: ClipboardItem(
            contentType: .text,
            contentHash: CryptoHelper.generateHash(
                for: "Preview text of the copied content goes here. It might be long and should truncate."),
            textPreview: "Preview text of the copied content goes here. It might be long and should truncate.",
            appName: "Safari",
            appIconName: "safari",
            rawText: "Preview text of the copied content goes here. It might be long and should truncate."
        ),
        viewModel: ClipboardViewModel()
    )
    .padding()
    .background(Color.black)
}
