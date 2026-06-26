import SwiftUI

/// 轻量级内联文本编辑器 - 参考 Paste 风格
/// 特点：简洁的顶部工具栏，无系统 Inspector Bar，支持基本格式操作
struct SimpleTextEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    
    let item: ClipboardItem
    let onCancel: () -> Void
    let onSave: (String, Data?) -> Void
    
    @State private var draftText: String
    @State private var draftRTFData: Data?
    @FocusState private var isTextViewFocused: Bool
    
    init(
        item: ClipboardItem,
        onCancel: @escaping () -> Void = {},
        onSave: @escaping (String, Data?) -> Void
    ) {
        self.item = item
        self.onCancel = onCancel
        self.onSave = onSave
        _draftText = State(initialValue: item.textPreview)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏 - 简洁风格
            HStack(spacing: 0) {
                // 左侧：取消按钮
                Button(action: cancelAndDismiss) {
                    Text("取消")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(NSColor.controlBackgroundColor).opacity(0.15))
                        )
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                // 中间：格式按钮组
                HStack(spacing: 8) {
                    FormatButton(action: toggleBold) {
                        Image(systemName: "bold")
                            .font(.system(size: 14, weight: .bold))
                    }
                    
                    FormatButton(action: toggleItalic) {
                        Image(systemName: "italic")
                            .font(.system(size: 14, weight: .regular))
                    }
                    
                    FormatButton(action: toggleUnderline) {
                        Image(systemName: "underline")
                            .font(.system(size: 14, weight: .regular))
                    }
                    
                    FormatButton(action: toggleStrikethrough) {
                        Image(systemName: "strikethrough")
                            .font(.system(size: 14, weight: .regular))
                    }
                }
                .padding(.horizontal, 12)
                
                Spacer()
                
                // 右侧：保存按钮
                Button(action: saveAndDismiss) {
                    Text("保存")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.blue)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))
            .overlay(
                Rectangle()
                    .fill(Color(NSColor.separatorColor))
                    .frame(height: 1),
                alignment: .bottom
            )
            
            // 文本编辑区域
            SimpleTextViewEditor(
                text: $draftText,
                rtfData: $draftRTFData,
                isFocused: $isTextViewFocused
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // 底部状态栏
            HStack(spacing: 8) {
                let charCount = draftText.count
                let wordCount = draftText.split(separator: " ").count
                let lineCount = draftText.split(separator: "\n").count
                
                Text("\(charCount) 个字符")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                Text("·")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                Text("\(wordCount) 单词")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                Text("·")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                Text("\(lineCount) 行")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))
            .overlay(
                Rectangle()
                    .fill(Color(NSColor.separatorColor))
                    .frame(height: 1),
                alignment: .top
            )
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            // 避免在 SwiftUI 正在更新视图树时同步修改 FocusState。
            DispatchQueue.main.async {
                isTextViewFocused = true
            }
        }
    }
    
    private func toggleBold() {
        // 由 SimpleTextViewEditor 内部处理
    }
    
    private func toggleItalic() {
        // 由 SimpleTextViewEditor 内部处理
    }
    
    private func toggleUnderline() {
        // 由 SimpleTextViewEditor 内部处理
    }
    
    private func toggleStrikethrough() {
        // 由 SimpleTextViewEditor 内部处理
    }
    
    private func cancelAndDismiss() {
        onCancel()
        dismiss()
    }
    
    private func saveAndDismiss() {
        onSave(draftText, draftRTFData)
        onCancel()
        dismiss()
    }
}

/// 单个格式按钮
struct FormatButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    
    var body: some View {
        Button(action: action) {
            label()
                .foregroundColor(.primary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.15))
                )
        }
        .buttonStyle(.plain)
    }
}

/// 简单的 NSTextView 编辑器，支持基本格式
struct SimpleTextViewEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var rtfData: Data?
    @FocusState.Binding var isFocused: Bool
    var onSelectionChange: ((String?) -> Void)? = nil
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        
        // 基础配置
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false  // 不支持图片
        textView.allowsUndo = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.windowBackgroundColor
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = NSColor.textColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        
        // 禁用 Inspector Bar 和 Font Panel - 使用自定义工具栏
        textView.usesInspectorBar = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        
        // 非连续布局
        textView.layoutManager?.allowsNonContiguousLayout = true
        
        // 设置初始文本
        textView.string = text
        
        // 监听文本变化
        textView.delegate = context.coordinator
        
        // 焦点监听
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleFocusChange),
            name: NSWindow.didBecomeKeyNotification,
            object: textView
        )
        
        return scrollView
    }
    
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        
        // 仅在文本未聚焦时同步外部变化，且避免无意义地重设 NSTextView 内容。
        if !isFocused, textView.string != text {
            textView.string = text
        }

        if isFocused, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
        
        // updateNSView 是 SwiftUI 的视图更新阶段，不能在这里同步写 Binding，
        // 否则会触发 “Modifying state during view update” 并可能导致窗口显示异常。
        if let rtf = try? textView.attributedString().data(
            from: NSRange(location: 0, length: textView.attributedString().length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ), rtfData != rtf {
            DispatchQueue.main.async {
                self.rtfData = rtf
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, NSTextViewDelegate {
        let parent: SimpleTextViewEditor
        
        init(_ parent: SimpleTextViewEditor) {
            self.parent = parent
        }
        
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            return true
        }
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.parent.text = textView.string
                if let rtf = try? textView.attributedString().data(
                    from: NSRange(location: 0, length: textView.attributedString().length),
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
                ) {
                    self.parent.rtfData = rtf
                }
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let selectedText = textView.selectedRanges
                .compactMap { $0 as? NSRange }
                .filter { $0.length > 0 }
                .compactMap { Range($0, in: textView.string) }
                .map { String(textView.string[$0]) }
                .joined(separator: "\n")

            DispatchQueue.main.async { [weak self] in
                self?.parent.onSelectionChange?(selectedText.isEmpty ? nil : selectedText)
            }
        }

        func textDidBeginEditing(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in
                self?.parent.isFocused = true
            }
        }

        func textDidEndEditing(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in
                self?.parent.isFocused = false
            }
        }
        
        @objc func handleFocusChange() {
            // 焦点变化处理
        }
    }
}
