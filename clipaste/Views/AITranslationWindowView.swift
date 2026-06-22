import SwiftUI

enum TranslationTargetLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case german = "de"
    case french = "fr"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .german: return "Deutsch"
        case .french: return "Français"
        }
    }

    var promptName: String {
        switch self {
        case .simplifiedChinese: return "Simplified Chinese"
        case .traditionalChinese: return "Traditional Chinese"
        case .english: return "English"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .german: return "German"
        case .french: return "French"
        }
    }
}

struct AITranslationWindowView: View {
    let windowID: String
    let title: String
    let sourceText: String
    let configuration: AIConfiguration

    @AppStorage("translationTargetLanguage") private var targetLanguage: TranslationTargetLanguage = .simplifiedChinese
    @State private var translatedText = ""
    @State private var isTranslating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            GeometryReader { proxy in
                if proxy.size.width < 680 {
                    VStack(spacing: 12) {
                        sourcePanel
                        translationPanel
                    }
                    .padding(16)
                } else {
                    HStack(spacing: 12) {
                        sourcePanel
                        translationPanel
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 460)
        .background {
            VisualEffectView(material: .popover, blendingMode: .behindWindow)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .task(id: targetLanguage) {
            await translate()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "character.bubble")
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? String(localized: "Translation") : title)
                    .font(.headline)
                Text(configuration.displayTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker(selection: $targetLanguage) {
                ForEach(TranslationTargetLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            } label: {
                Text("Translate To")
            }
            .pickerStyle(.menu)
            .frame(width: 180)
            .disabled(isTranslating)

            Button {
                AIConversationWindowManager.shared.close(windowID: windowID)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(LocalizedStringKey("Close"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var sourcePanel: some View {
        TranslationTextPanel(
            title: String(localized: "Original Text"),
            systemImage: "doc.text",
            text: sourceText,
            placeholder: nil
        )
    }

    private var translationPanel: some View {
        TranslationTextPanel(
            title: String(localized: "Translation"),
            systemImage: "sparkles",
            text: translatedText,
            placeholder: translationPlaceholder,
            isLoading: isTranslating,
            errorMessage: errorMessage
        )
    }

    private var translationPlaceholder: String? {
        if isTranslating {
            return String(localized: "Translating…")
        }
        if translatedText.isEmpty {
            return String(localized: "Translation will appear here.")
        }
        return nil
    }

    @MainActor
    private func translate() async {
        translatedText = ""
        errorMessage = nil
        isTranslating = true
        defer { isTranslating = false }

        do {
            let reply = try await AIExecutionService.shared.send(
                messages: [AIChatMessage(role: "user", content: translationPrompt)],
                configuration: configuration
            )
            guard Task.isCancelled == false else { return }
            translatedText = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            guard Task.isCancelled == false else { return }
            errorMessage = error.localizedDescription
        }
    }

    private var translationPrompt: String {
        """
        Translate the following plain text into \(targetLanguage.promptName). If it is a single word, provide the most common translation. Preserve URLs, email addresses, code-like identifiers, names, and paragraph breaks. Output only the translation.

        \(sourceText)
        """
    }
}

private struct TranslationTextPanel: View {
    let title: String
    let systemImage: String
    let text: String
    let placeholder: String?
    var isLoading = false
    var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            ScrollView {
                Text(contentText)
                    .font(.body)
                    .lineSpacing(4)
                    .foregroundStyle(contentForegroundStyle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var contentText: String {
        if text.isEmpty, let placeholder {
            return placeholder
        }
        return text
    }

    private var contentForegroundStyle: Color {
        text.isEmpty ? .secondary : .primary
    }
}
