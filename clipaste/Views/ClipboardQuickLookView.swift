import SwiftUI
import NaturalLanguage

struct ClipboardQuickLookView: View {
    let item: ClipboardItem
    @ObservedObject var viewModel: ClipboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if item.contentType == .image {
                ClipboardQuickLookImageView(viewModel: viewModel)
            } else if item.isFastLink {
                ClipboardQuickLookLinkContent(item: item, viewModel: viewModel)
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
                ClipboardQuickLookTextContent(item: item)
            }
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
        .frame(width: 420, alignment: .topLeading)
        .frame(minHeight: 160, alignment: .topLeading)
    }
}

private struct ClipboardQuickLookTextContent: View {
    let item: ClipboardItem

    @State private var highlightedAttr: NSAttributedString?
    @State private var translationState: QuickLookTranslationState = .idle

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
        NativeTextView(text: safeText, attributedText: highlightedAttr)
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
            .task(id: item.id) {
                await refreshTranslation()
            }
    }

    @ViewBuilder
    private var translationOverlay: some View {
        switch translationState {
        case .idle, .skipped:
            EmptyView()
        case .unavailable:
            EmptyView()
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
            translationCard {
                VStack(alignment: .leading, spacing: 6) {
                    Label("翻译", systemImage: "character.bubble")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text(text)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .lineLimit(8)
                        .textSelection(.enabled)
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

    private func translationCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(10)
            .frame(maxWidth: 640, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.12), radius: 6, y: 2)
            .padding(12)
    }

    @MainActor
    private func refreshTranslation() async {
        translationState = .idle

        guard let request = QuickLookTranslationRequest(item: item, text: safeText) else {
            translationState = .skipped
            return
        }

        guard let configuration = QuickLookAutoTranslator.activeConfiguration else {
            translationState = .unavailable(String(localized: "No active AI configuration is available."))
            return
        }

        try? await Task.sleep(for: .milliseconds(180))
        guard Task.isCancelled == false else { return }
        translationState = .translating

        do {
            let translated = try await QuickLookAutoTranslator.translate(request.text, configuration: configuration)
            guard Task.isCancelled == false else { return }
            translationState = .translated(translated)
        } catch {
            guard Task.isCancelled == false else { return }
            translationState = .failed(error.localizedDescription)
        }
    }

}

private enum QuickLookTranslationState: Equatable {
    case idle
    case skipped
    case unavailable(String)
    case translating
    case translated(String)
    case failed(String)
}

private struct QuickLookTranslationRequest {
    let text: String

    init?(item: ClipboardItem, text sourceText: String) {
        guard item.contentType == .text, item.hasRTF == false else {
            return nil
        }

        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard QuickLookAutoTranslator.shouldTranslate(text) else {
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
        guard text.isEmpty == false,
              text.count <= 5_000,
              isSimplifiedChinese(text) == false,
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
