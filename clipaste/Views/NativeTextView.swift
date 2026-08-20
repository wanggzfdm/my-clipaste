import SwiftUI
import AppKit

struct NativeTextView: NSViewRepresentable {
    enum Style {
        case plain
        case code
    }

    var text: String
    var attributedText: NSAttributedString?
    var style: Style = .plain
    var onSelectionChange: ((String?) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        guard let textView = scrollView.documentView as? NSTextView,
              let existingContainer = textView.textContainer else {
            return scrollView
        }

        // Reuse the existing textContainer so layoutManager/textStorage stay wired.
        let quickLookTextView = QuickLookSelectableTextView(frame: textView.frame, textContainer: existingContainer)
        quickLookTextView.delegate = context.coordinator
        scrollView.documentView = quickLookTextView

        quickLookTextView.isEditable = false
        quickLookTextView.isSelectable = true
        quickLookTextView.layoutManager?.allowsNonContiguousLayout = true
        quickLookTextView.isHorizontallyResizable = false
        quickLookTextView.isVerticallyResizable = true
        quickLookTextView.textContainer?.widthTracksTextView = true
        quickLookTextView.textContainer?.heightTracksTextView = false
        quickLookTextView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )

        configureTextView(quickLookTextView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        configureTextView(textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func configureTextView(_ textView: NSTextView) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(
            width: style == .code ? 16 : 20,
            height: style == .code ? 14 : 20
        )

        if let attrText = attributedText {
            // Avoid rewriting identical content so drag-selection is not cleared on SwiftUI refresh.
            updateTextView(textView, attributedText: attrText)
            applyBackgroundStyle(to: textView)
        } else {
            textView.font = .systemFont(ofSize: 14, weight: .regular)
            textView.textColor = NSColor.labelColor
            updateTextView(textView, string: text)
            applyBackgroundStyle(to: textView)
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

    private func applyBackgroundStyle(to textView: NSTextView) {
        guard style == .code else {
            textView.drawsBackground = false
            textView.backgroundColor = .clear
            return
        }

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        textView.drawsBackground = true
        textView.backgroundColor = isDark
            ? NSColor(red: 0.17, green: 0.18, blue: 0.23, alpha: 1.0)
            : NSColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 1.0)
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
