import SwiftUI
import NaturalLanguage
import os

struct ClipboardQuickLookView: View {
    let item: ClipboardItem
    @ObservedObject var viewModel: ClipboardViewModel

    @State private var selectedTextForCopy: String?

    var body: some View {
        Group {
            if usesEditorOnlyPreview {
                quickLookContent
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ClipboardQuickLookHeader(
                        item: item,
                        viewModel: viewModel,
                        selectedTextForCopy: selectedTextForCopy
                    )

                    quickLookContent
                }
                .padding(10)
            }
        }
        .onHover { hovering in
            viewModel.handleAutoPreviewPopoverHover(for: item, isHovering: hovering)
        }
        .onChange(of: item.id) { _, _ in
            selectedTextForCopy = nil
        }
    }

    private var usesEditorOnlyPreview: Bool {
        item.contentType != .image && item.fastParsedColor == nil
    }

    @ViewBuilder
    private var quickLookContent: some View {
        if item.contentType == .image {
            ClipboardQuickLookImageView(viewModel: viewModel)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.top, 8)
        } else if let parsedColor = item.fastParsedColor {
            ZStack {
                parsedColor
                Text(item.rawText ?? item.textPreview)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundColor(parsedColor.isDark ? .white : .black)
                    .textSelection(.enabled)
                    .padding(18)
            }
            .frame(width: 280, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.top, 8)
        } else {
            ClipboardQuickLookTextContent(
                item: item,
                viewModel: viewModel,
                selectedTextForCopy: $selectedTextForCopy
            )
        }
    }
}

private struct ClipboardQuickLookHeader: View {
    let item: ClipboardItem
    @ObservedObject var viewModel: ClipboardViewModel
    let selectedTextForCopy: String?

    private var canEditTextContent: Bool {
        item.contentType != .image
    }

    var body: some View {
        HStack(spacing: 10) {
            Button("关闭预览", systemImage: "xmark.circle.fill", action: viewModel.dismissQuickLook)
                .labelStyle(.iconOnly)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .accessibilityLabel("关闭预览")

            Text(item.typeBadgeTitle())
                .font(.title3.bold())
                .lineLimit(1)

            Spacer(minLength: 20)

            Button("更多", systemImage: "circle.dashed") {}
                .labelStyle(.iconOnly)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .buttonStyle(PasteBubbleIconButtonStyle())
                .disabled(true)
                .accessibilityHidden(true)

            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Button("复制", systemImage: "square.and.arrow.up") {
                viewModel.copyQuickLookItem(item, selectedText: selectedTextForCopy)
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 19, weight: .medium))
            .buttonStyle(PasteBubbleIconButtonStyle())
            .help(selectedTextForCopy == nil ? "复制全文" : "复制选中内容")

            Button("编辑") {
                viewModel.editItemContent(item: item)
            }
            .font(.headline)
            .buttonStyle(PasteBubbleEditButtonStyle())
            .disabled(canEditTextContent == false)
            .help(canEditTextContent ? "编辑并保存内容" : "此项目不支持文本编辑")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

private struct PasteBubbleIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 32, height: 32)
            .foregroundStyle(configuration.isPressed ? .primary : .secondary)
            .background(
                Circle()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.07))
            )
            .contentShape(Circle())
    }
}

private struct PasteBubbleEditButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .frame(height: 34)
            .foregroundStyle(.primary)
            .background(
                Capsule()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08))
            )
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            }
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
    @Binding var selectedTextForCopy: String?

    @State private var draftText: String
    @State private var draftRTFData: Data?
    @State private var lastLoadedItemID: UUID
    @FocusState private var isTextViewFocused: Bool

    init(
        item: ClipboardItem,
        viewModel: ClipboardViewModel,
        selectedTextForCopy: Binding<String?>
    ) {
        self.item = item
        self.viewModel = viewModel
        _selectedTextForCopy = selectedTextForCopy
        let initialText = Self.initialText(for: item)
        _draftText = State(initialValue: initialText)
        _lastLoadedItemID = State(initialValue: item.id)
    }

    var body: some View {
        SimpleTextViewEditor(
            text: $draftText,
            rtfData: $draftRTFData,
            isFocused: $isTextViewFocused,
            onSelectionChange: { selectedTextForCopy = $0 }
        )
        .frame(
            minWidth: 560,
            idealWidth: 700,
            maxWidth: 760,
            minHeight: 360,
            idealHeight: 430,
            maxHeight: 560
        )
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .padding(10)
        .onAppear(perform: focusEditor)
        .onChange(of: item.id) { _, _ in
            reloadDraftIfNeeded()
            focusEditor()
        }
    }

    private static func initialText(for item: ClipboardItem) -> String {
        item.rawText ?? item.previewText ?? item.textPreview
    }

    private func reloadDraftIfNeeded() {
        guard lastLoadedItemID != item.id else { return }
        lastLoadedItemID = item.id
        draftText = Self.initialText(for: item)
        draftRTFData = nil
        selectedTextForCopy = nil
    }

    private func focusEditor() {
        DispatchQueue.main.async {
            isTextViewFocused = true
        }
    }
}

private struct ClipboardQuickLookFooter: View {
    let text: String
    let item: ClipboardItem
    @ObservedObject var viewModel: ClipboardViewModel

    private var characterCount: Int { text.count }

    private var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private var lineCount: Int {
        max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count)
    }

    var body: some View {
        HStack(spacing: 10) {
            footerText("\(characterCount) 个字符")
            separator
            footerText("\(wordCount) 单词")
            separator
            footerText("\(lineCount) 行")

            Spacer(minLength: 18)

            ClipboardQuickLookGroupMenu(item: item, viewModel: viewModel)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var separator: some View {
        Text("·")
            .font(.callout)
            .foregroundStyle(.secondary.opacity(0.55))
    }

    private func footerText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private struct ClipboardQuickLookGroupMenu: View {
    let item: ClipboardItem
    @ObservedObject var viewModel: ClipboardViewModel

    private var canAssignGroup: Bool {
        viewModel.customGroups.isEmpty == false
    }

    var body: some View {
        Menu {
            if viewModel.customGroups.isEmpty {
                Text("No Groups")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.customGroups) { group in
                    Button {
                        viewModel.assignQuickLookItem(item, to: group)
                    } label: {
                        if item.groupIDs.contains(group.id) {
                            Label {
                                Text(verbatim: group.name)
                            } icon: {
                                Image(systemName: "checkmark")
                            }
                        } else {
                            GroupMenuLabel(title: group.name, iconName: group.systemIconName)
                        }
                    }
                    .disabled(item.groupIDs.contains(group.id))
                }
            }
        } label: {
            HStack(spacing: -7) {
                Circle().fill(Color.blue.opacity(0.78))
                Circle().fill(Color.purple.opacity(0.78))
                Circle().fill(Color.pink.opacity(0.78))
            }
            .frame(width: 52, height: 22)
            .blur(radius: canAssignGroup ? 0.2 : 1.4)
            .opacity(canAssignGroup ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(canAssignGroup == false)
        .help(canAssignGroup ? "加入分组" : "暂无自定义分组")
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
