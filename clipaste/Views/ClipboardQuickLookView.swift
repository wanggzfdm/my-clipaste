import SwiftUI
import NaturalLanguage
import os

struct ClipboardQuickLookView: View {
    let item: ClipboardItem
    @ObservedObject var viewModel: ClipboardViewModel
    @State private var isHoveringCloseButton = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                if item.contentType == .image {
                    ClipboardQuickLookImageView(viewModel: viewModel)
                } else if let parsedColor = item.fastParsedColor {
                    // 颜色预览：大色块 + 对比色等宽文字
                    ZStack {
                        parsedColor
                        Text(item.rawText ?? item.textPreview)
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                            .foregroundColor(parsedColor.isDark ? .white : .black)
                    }
                    .frame(width: 280, height: 120)

                } else {
                    ClipboardQuickLookTextContent(item: item, viewModel: viewModel)
                }
            }
            .onHover { hovering in
                viewModel.handleAutoPreviewPopoverHover(for: item, isHovering: hovering)
            }
            
            // 关闭按钮
            Button(action: {
                viewModel.dismissQuickLook()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(isHoveringCloseButton ? .primary : .secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(.ultraThinMaterial)
                            .opacity(isHoveringCloseButton ? 0.85 : 0.6)
                    )
            }
            .buttonStyle(.plain)
            .padding(12)
            .onHover { hovering in
                isHoveringCloseButton = hovering
            }
            .help("关闭预览")
        }
        // Popover 原生自带材质背景，无需额外设置
    }
}

private struct ClipboardQuickLookLinkContent: View {
    let item: ClipboardItem
    @ObservedObject var viewModel: ClipboardViewModel

    var body: some View {
        Group {
            switch viewModel.settingsViewModel.linkDisplayMode {
            case .rich:
                ClipboardLinkPreviewCardView(
                    viewModel: ClipboardLinkPreviewViewModel(item: item),
                    highlight: viewModel.activeSearchQuery
                )
            case .plain:
                ClipboardLinkPlainCardView(
                    viewModel: ClipboardLinkPreviewViewModel(item: item),
                    highlight: viewModel.activeSearchQuery
                )
            }
        }
        .padding(16)
        .frame(width: 520, alignment: .topLeading)
        .frame(minHeight: 240, alignment: .topLeading)
    }
}

private struct ClipboardQuickLookTextContent: View {
    let item: ClipboardItem
    @ObservedObject var viewModel: ClipboardViewModel

    @State private var highlightedAttr: NSAttributedString?
    @State private var translationState: QuickLookTranslationState = .idle
    @State private var isHoveringTranslation = false

    private var safeText: String {
        let fullText = item.rawText ?? item.textPreview
        if fullText.utf8.count > 200_000 {
            return String(fullText.prefix(100_000))
                + "\n\n"
                + String(localized: "Preview truncated to protect memory. Pasting is not affected.")
        }
        return fullText
    }

    var body: some View {
        NativeTextView(
            text: safeText,
            attributedText: highlightedAttr,
            onTranslateSelection: translateSelectedText
        )
            .frame(
                minWidth: 400,
                idealWidth: 500,
                maxWidth: 700,
                minHeight: 300,
                idealHeight: 400,
                maxHeight: 600
            )
            .overlay(alignment: .bottomLeading) {
                translationOverlay
            }
            .padding(16)
            .task(id: item.contentHash) {
                highlightedAttr = await ClipboardQuickLookTextLoader.loadHighlightedText(for: item)
            }
            .task(id: translationTaskID) {
                await refreshTranslation()
            }
    }

    private var translationTaskID: String {
        "\(item.id)-\(viewModel.forceQuickLookTranslate)-\(viewModel.quickLookTranslationOverrideText?.hashValue ?? 0)"
    }

    private func translateSelectedText(_ text: String) {
        viewModel.quickLookTranslationOverrideText = text
        viewModel.forceQuickLookTranslate = true
    }

    @ViewBuilder
    private var translationOverlay: some View {
        switch translationState {
        case .idle:
            EmptyView()
        case .skipped(let message), .unavailable(let message):
            translationCard {
                Label(message, systemImage: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .translating:
            translationCard {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)

                    Text("Translating preview…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        case .translated(let text):
            translationCard(isInteractive: true) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(viewModel.quickLookTranslationOverrideText == nil ? "翻译" : "翻译选中内容", systemImage: "character.bubble")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text(text)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .lineLimit(8)
                        .textSelection(.enabled)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture {
                viewModel.copyQuickLookTranslation(text)
            }
            .onHover { hovering in
                isHoveringTranslation = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        case .failed(let message):
            translationCard {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func translationCard<Content: View>(
        isInteractive: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(10)
            .frame(maxWidth: 640, alignment: .leading)
            .background(
                isInteractive && isHoveringTranslation
                    ? AnyShapeStyle(.selection.opacity(0.18))
                    : AnyShapeStyle(.regularMaterial),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isInteractive && isHoveringTranslation
                            ? Color.accentColor.opacity(0.35)
                            : Color.primary.opacity(0.08),
                        lineWidth: 1
                    )
            }
            .shadow(color: Color.black.opacity(0.12), radius: 6, y: 2)
            .padding(12)
    }

    @MainActor
    private func refreshTranslation() async {
        translationState = .idle

        os_log("[QuickLookTranslation] Starting for item: %{public}@, contentType: %{public}@, hasRTF: %{public}d", type: .info, item.id.uuidString, item.contentType.rawValue, item.hasRTF)

        let forceTranslate = viewModel.forceQuickLookTranslate
        guard forceTranslate else {
            os_log("[QuickLookTranslation] Skipped: translation was not explicitly requested", type: .info)
            return
        }

        let sourceText = viewModel.quickLookTranslationOverrideText ?? safeText
        guard let request = QuickLookTranslationRequest(item: item, text: sourceText, forceTranslate: forceTranslate) else {
            os_log("[QuickLookTranslation] Skipped: request unavailable", type: .info)
            translationState = .skipped(String(localized: "Preview translation is available for text content."))
            return
        }

        guard let configuration = QuickLookAutoTranslator.activeConfiguration else {
            let settings = AISettingsViewModel.shared
            os_log("[QuickLookTranslation] No active config: isAIEnabled=%{public}d, activeID=%{public}@, configsCount=%{public}d", type: .error, settings.isAIEnabled ? 1 : 0, settings.activeConfigurationID?.uuidString ?? "nil", settings.configurations.count)
            translationState = .unavailable(String(localized: "No active AI configuration is available."))
            return
        }

        try? await Task.sleep(for: .milliseconds(180))
        guard Task.isCancelled == false else { return }
        translationState = .translating

        do {
            os_log("[QuickLookTranslation] Running preview translation skill (%{public}d chars)", type: .info, request.text.count)
            let translated = try await QuickLookAutoTranslator.translate(item: item, text: request.text, configuration: configuration)
            guard Task.isCancelled == false else { return }
            translationState = .translated(translated)
        } catch {
            os_log("[QuickLookTranslation] Failed: %{public}@", type: .error, error.localizedDescription)
            guard Task.isCancelled == false else { return }
            translationState = .failed(error.localizedDescription)
        }
    }

}

private enum QuickLookTranslationState: Equatable {
    case idle
    case skipped(String)
    case unavailable(String)
    case translating
    case translated(String)
    case failed(String)
}

private struct QuickLookTranslationRequest {
    let text: String

    init?(item: ClipboardItem, text sourceText: String, forceTranslate: Bool = false) {
        guard item.contentType == .text || item.contentType == .code || item.contentType == .link else {
            return nil
        }

        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false, text.count <= 5_000 else {
            return nil
        }

        if !forceTranslate && !QuickLookAutoTranslator.shouldTranslate(text) {
            return nil
        }

        self.text = text
    }
}

private enum QuickLookAutoTranslator {
    static var activeConfiguration: AIConfiguration? {
        let settings = AISettingsViewModel.shared
        guard settings.isAIEnabled else { return nil }
        return settings.activeConfiguration
    }

    static func translate(item: ClipboardItem, text: String, configuration: AIConfiguration) async throws -> String {
        let skill = AISkill(
            name: String(localized: "Preview Translation"),
            promptTemplate: """
            Translate the following plain text into Simplified Chinese. If it is a single word, provide the most common Simplified Chinese translation. Preserve URLs, email addresses, code-like identifiers, names, and paragraph breaks. Output only the translation.

            \(text)
            """,
            supportedContentTypes: [.text, .code, .link],
            outputMode: .openConversation
        )
        let prompt = try await AIExecutionService.shared.prompt(for: skill, item: item)
        return try await AIExecutionService.shared.send(
            messages: [AIChatMessage(role: "user", content: prompt)],
            configuration: configuration
        )
    }

    static func shouldTranslate(_ text: String) -> Bool {
        guard isSimplifiedChinese(text) == false,
              isLikelyStructuredOrCode(text) == false else {
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
                || scalar == "'"
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
