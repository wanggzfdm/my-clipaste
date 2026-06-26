import SwiftUI
import AppKit

struct NativeTextView: NSViewRepresentable {
    var text: String
    var attributedText: NSAttributedString?
    var onTranslateSelection: ((String) -> Void)?
    var onSelectionChange: ((String?) -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        guard let textView = scrollView.documentView as? NSTextView,
              let existingContainer = textView.textContainer else { return scrollView }
        // 使用 init(frame:textContainer:) 直接复用已有的 textContainer，
        // 避免二次赋值导致 layoutManager/textStorage 绑定断裂。
        let quickLookTextView = QuickLookSelectableTextView(frame: textView.frame, textContainer: existingContainer)
        quickLookTextView.delegate = context.coordinator
        scrollView.documentView = quickLookTextView

        // 核心配置：只读、可选中
        quickLookTextView.isEditable = false
        quickLookTextView.isSelectable = true
        quickLookTextView.onTranslateSelection = onTranslateSelection

        // 极其关键：开启非连续布局，允许巨量文本在后台分块渲染
        quickLookTextView.layoutManager?.allowsNonContiguousLayout = true

        quickLookTextView.textContainerInset = NSSize(width: 20, height: 20)

        configureTextView(quickLookTextView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        (textView as? QuickLookSelectableTextView)?.onTranslateSelection = onTranslateSelection
        context.coordinator.parent = self
        configureTextView(textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func configureTextView(_ textView: NSTextView) {
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true

        if let attrText = attributedText {
            // 语法高亮模式：只在内容真正变化时替换，避免 SwiftUI 更新清掉用户选区。
            updateTextView(textView, attributedText: attrText)
        } else {
            // 纯文本降级模式：只在内容真正变化时替换，避免拖选时 selection 被重置。
            textView.font = .systemFont(ofSize: 14, weight: .regular)
            textView.textColor = NSColor.labelColor
            updateTextView(textView, string: text)
        }
    }

    private func updateTextView(_ textView: NSTextView, attributedText: NSAttributedString) {
        guard textView.attributedString() != attributedText else { return }
        let selectedRanges = textView.selectedRanges
        textView.textStorage?.setAttributedString(attributedText)
        restore(selectedRanges: selectedRanges, in: textView)
    }

    private func updateTextView(_ textView: NSTextView, string: String) {
        guard textView.string != string else { return }
        let selectedRanges = textView.selectedRanges
        textView.string = string
        restore(selectedRanges: selectedRanges, in: textView)
    }

    private func restore(selectedRanges: [NSValue], in textView: NSTextView) {
        let textLength = (textView.string as NSString).length
        let restoredRanges = selectedRanges.compactMap { value -> NSValue? in
            let range = value.rangeValue
            guard range.location <= textLength else { return nil }
            let boundedLength = min(range.length, textLength - range.location)
            return NSValue(range: NSRange(location: range.location, length: boundedLength))
        }
        guard restoredRanges.isEmpty == false else { return }
        textView.selectedRanges = restoredRanges
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeTextView

        init(parent: NativeTextView) {
            self.parent = parent
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.onSelectionChange?(textView.selectedTextForAction())
        }
    }
}

private final class QuickLookSelectableTextView: NSTextView {
    var onTranslateSelection: ((String) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func copy(_ sender: Any?) {
        guard let selectedText = selectedTextForAction(), selectedText.isEmpty == false else {
            super.copy(sender)
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedText, forType: .string)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isTranslateSelectionShortcut = event.keyCode == 49
            && modifiers.contains(.shift)
            && modifiers.isDisjoint(with: [.command, .control, .option])

        if isTranslateSelectionShortcut,
           let selectedText = selectedTextForTranslation() {
            onTranslateSelection?(selectedText)
            return
        }

        super.keyDown(with: event)
    }

    private func selectedTextForTranslation() -> String? {
        selectedTextForAction()?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private extension NSTextView {
    func selectedTextForAction() -> String? {
        let selectedRange = selectedRange()
        guard selectedRange.length > 0 else {
            return nil
        }

        let source = string as NSString
        guard NSMaxRange(selectedRange) <= source.length else {
            return nil
        }

        let selectedText = source.substring(with: selectedRange)
        return selectedText.isEmpty ? nil : selectedText
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
