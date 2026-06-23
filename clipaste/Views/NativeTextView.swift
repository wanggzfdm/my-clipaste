import SwiftUI
import AppKit

struct NativeTextView: NSViewRepresentable {
    var text: String
    var attributedText: NSAttributedString?
    var onTranslateSelection: ((String) -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        guard let textView = scrollView.documentView as? NSTextView,
              let existingContainer = textView.textContainer else { return scrollView }
        let existingDelegate = textView.delegate
        // 使用 init(frame:textContainer:) 直接复用已有的 textContainer，
        // 避免二次赋值导致 layoutManager/textStorage 绑定断裂。
        let quickLookTextView = QuickLookSelectableTextView(frame: textView.frame, textContainer: existingContainer)
        quickLookTextView.delegate = existingDelegate
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
        configureTextView(textView)
    }

    private func configureTextView(_ textView: NSTextView) {
        if let attrText = attributedText {
            // 语法高亮模式：不绘制背景，保留窗口的系统毛玻璃
            textView.drawsBackground = false
            textView.textStorage?.setAttributedString(attrText)
        } else {
            // 纯文本降级模式
            textView.drawsBackground = false
            textView.font = .systemFont(ofSize: 14, weight: .regular)
            textView.textColor = NSColor.labelColor
            textView.string = text
        }
    }
}

private final class QuickLookSelectableTextView: NSTextView {
    var onTranslateSelection: ((String) -> Void)?

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
        let selectedRange = selectedRange()
        guard selectedRange.length > 0 else {
            return nil
        }

        let source = string as NSString
        guard NSMaxRange(selectedRange) <= source.length else {
            return nil
        }

        let selectedText = source
            .substring(with: selectedRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return selectedText.isEmpty ? nil : selectedText
    }
}
