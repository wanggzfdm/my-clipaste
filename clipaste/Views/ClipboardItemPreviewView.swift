import SwiftUI
import os
import AppKit
import NaturalLanguage

/// Preview panel that shows full content of a clipboard item when hovered/focused
/// in the vertical list layout.
struct ClipboardItemPreviewView: View {
    let item: ClipboardItem

    @AppStorage("clipboardLayout") private var clipboardLayout: AppLayoutMode = .horizontal
    @State private var translationState: PreviewTranslationState = .idle

    private var isCompact: Bool {
        clipboardLayout == .compact
    }

    private var panelMinWidth: CGFloat {
        isCompact ? 300 : 420
    }

    private var panelIdealWidth: CGFloat {
        isCompact ? 360 : 520
    }

    private var panelMaxWidth: CGFloat {
        isCompact ? 420 : 680
    }

    private var panelCornerRadius: CGFloat {
        isCompact ? 10 : 14
    }

    private var padding: CGFloat {
        isCompact ? 12 : 16
    }

    private var panelMinHeight: CGFloat {
        isCompact ? 200 : 280
    }

    private var panelIdealHeight: CGFloat {
        isCompact ? 300 : 400
    }

    private var headerHeight: CGFloat {
        isCompact ? 44 : 56
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with type badge and timestamp
            headerView
                .frame(height: headerHeight)
            
            Divider()
                .opacity(0.1)
            
            // Content area
            ScrollView {
                contentView
                    .padding(padding)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: panelMinWidth,
            idealWidth: panelIdealWidth,
            maxWidth: panelMaxWidth,
            minHeight: panelMinHeight,
            idealHeight: panelIdealHeight,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .layoutPriority(1)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(.rect(cornerRadius: panelCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: panelCornerRadius)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 12, y: 4)
    }
    
    // MARK: - Header View
    
    @ViewBuilder
    private var headerView: some View {
        HStack(spacing: 12) {
            // Type badge
            HStack(spacing: 4) {
                Image(systemName: item.contentType.systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(item.typeBadgeTitle())
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(typeBadgeColor)
            .clipShape(Capsule())
            
            Spacer()
            
            // Timestamp
            VStack(alignment: .trailing, spacing: 1) {
                Text(item.timestamp.timeString)
                    .font(.system(size: 12, weight: .medium))
                Text(item.timestamp.dateString)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // DEBUG: translation state
            Text(debugStateLabel)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.red)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.yellow.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .padding(.horizontal, padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
    
    private var debugStateLabel: String {
        switch translationState {
        case .idle: return "TR:idle"
        case .skipped: return "TR:skipped"
        case .unavailable(let msg): return "TR:unavail(\(msg.prefix(20)))"
        case .translating: return "TR:translating"
        case .translated: return "TR:done"
        case .failed(let msg): return "TR:fail(\(msg.prefix(20)))"
        }
    }

    private var typeBadgeColor: Color {
        switch item.contentType {
        case .text: return .blue
        case .image: return .purple
        case .fileURL: return .orange
        case .color: return .pink
        case .link: return .green
        case .code: return .gray
        }
    }
    
    // MARK: - Content View
    
    @ViewBuilder
    private var contentView: some View {
        switch item.contentType {
        case .text:
            textContentView
        case .image:
            imageContentView
        case .fileURL:
            fileContentView
        case .color:
            colorContentView
        case .link:
            textContentView
        case .code:
            codeContentView
        }
    }
    
    // MARK: - Text Content
    
    @ViewBuilder
    private var textContentView: some View {
        if let rawText = item.rawText, !rawText.isEmpty {
            let hasTranslation = {
                switch translationState {
                case .idle, .skipped: return false
                case .unavailable, .translating, .translated, .failed: return true
                }
            }()

            VStack(alignment: .leading, spacing: 0) {
                // Original text section
                VStack(alignment: .leading, spacing: 8) {
                    if hasTranslation {
                        Label("原文", systemImage: "doc.text")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                    wrappedContentText(
                        rawText,
                        font: .system(size: isCompact ? 13 : 15, design: .default),
                        lineSpacing: isCompact ? 4 : 6
                    )
                }

                // Translation section
                if hasTranslation {
                    Divider()
                        .opacity(0.15)
                        .padding(.vertical, 10)

                    translationView
                }

                // Metadata
                metadataView(textLength: rawText.utf8.count)

            }
        } else {
            emptyContentPlaceholder
        }
    }
    
    // MARK: - Image Content
    
    @ViewBuilder
    private var imageContentView: some View {
        VStack(spacing: 12) {
            if item.hasImagePreview || item.hasImageData {
                ZStack {
                    CheckerboardBackground()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    
                    ClipboardThumbnailView(itemID: item.id, maxPixelSize: isCompact ? 400 : 600) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.secondary)
                    }
                }
                .frame(maxHeight: .infinity)
                .frame(height: isCompact ? 200 : 280)
                
                // Image dimensions if available
                if let pixelSize = item.imagePixelSize {
                    HStack {
                        Image(systemName: "photo")
                            .foregroundColor(.secondary)
                        Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                emptyContentPlaceholder
            }
        }
    }
    
    // MARK: - File Content
    
    @ViewBuilder
    private var fileContentView: some View {
        if let fileURL = item.resolvedFileURL {
            let displayPath = item.fileDisplayPath ?? fileURL.path
            
            VStack(spacing: 16) {
                if item.fileRepresentsImage {
                    // Show large thumbnail for image files
                    ZStack {
                        CheckerboardBackground()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        
                        ClipboardFileThumbnailView(fileURL: fileURL, maxPixelSize: isCompact ? 300 : 480) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: displayPath))
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 64, height: 64)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: isCompact ? 160 : 220)
                } else {
                    // Show file icon and details
                    VStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: displayPath))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: isCompact ? 64 : 80, height: isCompact ? 64 : 80)
                        
                        VStack(spacing: 4) {
                            Text(item.fileDisplayName ?? (displayPath as NSString).lastPathComponent)
                                .font(.system(size: isCompact ? 13 : 15, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .multilineTextAlignment(.center)

                            Text(displayPath)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .multilineTextAlignment(.center)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        } else {
            emptyContentPlaceholder
        }
    }
    
    // MARK: - Color Content
    
    @ViewBuilder
    private var colorContentView: some View {
        if let parsedColor = item.fastParsedColor {
            VStack(spacing: 16) {
                // Large color swatch
                RoundedRectangle(cornerRadius: 12)
                    .fill(parsedColor)
                    .frame(height: isCompact ? 100 : 140)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
                    .shadow(color: parsedColor.opacity(0.3), radius: 8, y: 4)
                
                // Color value
                if let previewText = item.previewText, !previewText.isEmpty {
                    Text(previewText)
                        .font(.system(size: isCompact ? 14 : 16, weight: .semibold, design: .monospaced))
                        .foregroundColor(parsedColor.isDark ? .white : .black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(parsedColor.opacity(0.2))
                        )
                }
            }
        } else {
            emptyContentPlaceholder
        }
    }
    
    // MARK: - Link Content
    
    @ViewBuilder
    private var linkContentView: some View {
        ClipboardLinkPreviewCardView(
            viewModel: ClipboardLinkPreviewViewModel(item: item),
            highlight: ""
        )
        .padding(isCompact ? 2 : 4)
        .frame(
            minHeight: isCompact ? 120 : 150,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }
    
    // MARK: - Code Content
    
    @ViewBuilder
    private var codeContentView: some View {
        if let rawText = item.rawText, !rawText.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                wrappedContentText(
                    rawText,
                    font: .system(size: isCompact ? 12 : 13, design: .monospaced),
                    lineSpacing: isCompact ? 3 : 4
                )

                metadataView(textLength: rawText.utf8.count)
            }
        } else {
            emptyContentPlaceholder
        }
    }
    
    // MARK: - Helpers
    
    @ViewBuilder
    private func metadataView(textLength: Int) -> some View {
        HStack(spacing: 16) {
            if textLength > 0 {
                Label("\(textLength) chars", systemImage: "text.alignleft")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            
            if item.sourceBundleIdentifier != nil {
                Label(item.appName, systemImage: "app.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func wrappedContentText(
        _ text: String,
        font: Font,
        lineSpacing: CGFloat = 0,
        foregroundStyle: some ShapeStyle = .primary
    ) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(foregroundStyle)
            .lineSpacing(lineSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private var translationView: some View {
        switch translationState {
        case .idle, .skipped:
            EmptyView()
        case .unavailable(let message):
            Label(message, systemImage: "sparkles")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .translating:
            VStack(alignment: .leading, spacing: 8) {
                Label("翻译", systemImage: "character.bubble")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)

                    Text("正在翻译…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        case .translated(let text):
            VStack(alignment: .leading, spacing: 8) {
                Label("翻译", systemImage: "character.bubble")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                wrappedContentText(
                    text,
                    font: .system(size: isCompact ? 13 : 15, design: .default),
                    lineSpacing: isCompact ? 4 : 6
                )
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("翻译", systemImage: "character.bubble")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @MainActor
    private func refreshPreviewTranslation() async {
        translationState = .idle
        os_log("[PreviewTranslation] Starting for item: %{public}@, contentType: %{public}@, hasRTF: %{public}d", type: .info, item.id.uuidString, item.contentType.rawValue, item.hasRTF)

        guard let request = PreviewAutoTranslationRequest(item: item) else {
            let rawText = item.rawText?.prefix(100) ?? "nil"
            os_log("[PreviewTranslation] Request creation failed: rawText= %{public}@", type: .error, String(rawText))
            translationState = .skipped
            return
        }

        guard let configuration = PreviewAutoTranslator.activeConfiguration else {
            let settings = AISettingsViewModel.shared
            os_log("[PreviewTranslation] No active config: isAIEnabled= %{public}d, activeID= %{public}@, configsCount= %{public}d", type: .error, settings.isAIEnabled ? 1 : 0, settings.activeConfigurationID?.uuidString ?? "nil", settings.configurations.count)
            translationState = .unavailable(String(localized: "No active AI configuration is available."))
            return
        }

        translationState = .translating
        os_log("[PreviewTranslation] Translating text (%{public}d chars)", type: .info, request.text.count)

        do {
            let translated = try await PreviewAutoTranslator.translate(request.text, configuration: configuration)
            guard Task.isCancelled == false else { return }
            translationState = .translated(translated)
        } catch {
            guard Task.isCancelled == false else { return }
            translationState = .failed(error.localizedDescription)
        }
    }

    @ViewBuilder
    private var emptyContentPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            
            Text("No preview available")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(height: isCompact ? 120 : 180)
    }
}

private enum PreviewTranslationState: Equatable {
    case idle
    case skipped
    case unavailable(String)
    case translating
    case translated(String)
    case failed(String)
}

private struct PreviewAutoTranslationRequest {
    let text: String

    init?(item: ClipboardItem) {
        os_log("[PreviewTranslationRequest] Checking: contentType= %{public}@, hasRTF= %{public}d", type: .info, item.contentType.rawValue, item.hasRTF)
        guard item.contentType == .text, item.hasRTF == false else {
            os_log("[PreviewTranslationRequest] Failed: not text or hasRTF", type: .error)
            return nil
        }

        let text = (item.rawText ?? item.previewText ?? item.textPreview)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        os_log("[PreviewTranslationRequest] Extracted %{public}d chars", type: .info, text.count)
        guard PreviewAutoTranslator.shouldTranslate(text) else {
            os_log("[PreviewTranslationRequest] shouldTranslate returned false", type: .default)
            return nil
        }

        self.text = text
    }
}

private enum PreviewAutoTranslator {
    static var activeConfiguration: AIConfiguration? {
        let settings = AISettingsViewModel.shared
        guard settings.isAIEnabled else { return nil }
        return settings.activeConfiguration
    }

    static func translate(_ text: String, configuration: AIConfiguration) async throws -> String {
        let prompt = """
        Translate the following plain text into Simplified Chinese. If it is a single word, provide the most common Simplified Chinese translation. Preserve URLs, email addresses, code-like identifiers, names, and paragraph breaks. Output only the translation.

        \(text)
        """

        return try await AIExecutionService.shared.send(
            messages: [AIChatMessage(role: "user", content: prompt)],
            configuration: configuration
        )
    }

    static func shouldTranslate(_ text: String) -> Bool {
        os_log("[PreviewAutoTranslator.shouldTranslate] Checking %{public}d chars", type: .info, text.count)
        let isChinese = isSimplifiedChinese(text)
        let isStructured = isLikelyStructuredOrCode(text)
        os_log("[PreviewAutoTranslator.shouldTranslate] isChinese= %{public}d, isStructured= %{public}d", type: .info, isChinese ? 1 : 0, isStructured ? 1 : 0)
        guard text.isEmpty == false,
              text.count <= 5_000,
              isChinese == false,
              isStructured == false else {
            return false
        }

        return isSingleWord(text) || isLikelyNaturalLanguage(text)
    }

    private static func isSimplifiedChinese(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)

        if recognizer.dominantLanguage == .simplifiedChinese {
            return true
        }

        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        return (hypotheses[.simplifiedChinese] ?? 0) >= 0.45
    }

    private static func isSingleWord(_ text: String) -> Bool {
        guard text.contains(where: \.isWhitespace) == false,
              text.unicodeScalars.count <= 64 else {
            return false
        }

        return text.unicodeScalars.allSatisfy { scalar in
            CharacterSet.letters.contains(scalar)
                || CharacterSet.nonBaseCharacters.contains(scalar)
                || scalar == "'"
                || scalar == "-"
                || scalar == "’"
        }
    }

    private static func isLikelyNaturalLanguage(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        let meaningfulScalars = scalars.filter { CharacterSet.whitespacesAndNewlines.contains($0) == false }
        guard meaningfulScalars.count >= 8 else { return false }

        let letterCount = meaningfulScalars.filter { CharacterSet.letters.contains($0) }.count
        let letterRatio = Double(letterCount) / Double(meaningfulScalars.count)
        guard letterRatio >= 0.45 else { return false }

        let sentenceMarks = text.filter { ".!?。！？".contains($0) }.count
        let wordSeparators = text.filter(\.isWhitespace).count
        return sentenceMarks > 0 || wordSeparators > 0
    }

    private static func isLikelyStructuredOrCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            return true
        }

        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
            || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
            || (trimmed.hasPrefix("<") && trimmed.hasSuffix(">")) {
            return true
        }

        let codeNeedles = [
            "func ", "let ", "var ", "class ", "struct ", "enum ", "import ",
            "const ", "function ", "return ", "#include", "public ", "private "
        ]
        if codeNeedles.contains(where: { lowercased.contains($0) }) {
            return true
        }

        let codeSymbolCount = trimmed.filter { "{}[]<>;=|`$".contains($0) }.count
        return Double(codeSymbolCount) / Double(max(trimmed.count, 1)) > 0.08
    }
}

// MARK: - Checkerboard Background

/// Classic gray-white checkerboard pattern for transparent image visualization
private struct CheckerboardBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    let cellSize: CGFloat = 10

    private var lightColor: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(calibratedWhite: 0.16, alpha: 0.85))
            : Color.white.opacity(0.9)
    }

    private var darkColor: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(calibratedWhite: 0.09, alpha: 0.90))
            : Color.gray.opacity(0.2)
    }
    
    var body: some View {
        Canvas { context, size in
            let cols = Int(ceil(size.width / cellSize))
            let rows = Int(ceil(size.height / cellSize))
            for row in 0..<rows {
                for col in 0..<cols {
                    let isEven = (row + col) % 2 == 0
                    let rect = CGRect(
                        x: CGFloat(col) * cellSize,
                        y: CGFloat(row) * cellSize,
                        width: cellSize,
                        height: cellSize
                    )
                    context.fill(Path(rect), with: .color(isEven ? lightColor : darkColor))
                }
            }
        }
        .accessibilityLabel("Checkerboard pattern for transparent image background")
    }
}

#Preview {
    HStack(spacing: 20) {
        ClipboardItemPreviewView(
            item: ClipboardItem(
                contentType: .text,
                contentHash: "preview1",
                textPreview: "Sample text content for preview",
                appName: "Safari",
                appIconName: "safari",
                rawText: "This is a longer piece of text that would normally be truncated in the list view. Now we can see the full content in the preview panel.\n\nIt can span multiple lines and include paragraphs."
            )
        )

        ClipboardItemPreviewView(
            item: ClipboardItem(
                contentType: .code,
                contentHash: "preview2",
                textPreview: "let greeting = \"Hello, World!\"",
                appName: "Xcode",
                appIconName: "xcode",
                rawText: "func greet(name: String) -> String {\n    return \"Hello, \\(name)!\"\n}\n\ngreet(name: \"World\")"
            )
        )
    }
    .padding()
    .background(Color.black)
}
