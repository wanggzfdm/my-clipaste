import SwiftUI

struct ClipboardVerticalView: View {
    let items: [ClipboardItem]
    @ObservedObject var viewModel: ClipboardViewModel
    @AppStorage("singleClickPaste") private var singleClickPaste = true
    @AppStorage("autoPreview") private var autoPreview = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 16) {
                ForEach(items) { item in
                    ClipboardCardView(item: item, viewModel: viewModel)
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                        .help(pasteHelpText)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: viewModel.selectedItemIDs) { _, _ in
            viewModel.presentAutoPreviewForSelectionIfNeeded(isEnabled: shouldTriggerPreview)
        }
        .onChange(of: autoPreview) { _, _ in
            viewModel.presentAutoPreviewForSelectionIfNeeded(isEnabled: shouldTriggerPreview)
        }
        .onChange(of: viewModel.isPreviewModifierHeld) { _, _ in
            viewModel.presentAutoPreviewForSelectionIfNeeded(isEnabled: shouldTriggerPreview)
        }
    }

    private var pasteHelpText: Text {
        if singleClickPaste {
            Text("单击复制，双击粘贴到当前应用")
        } else {
            Text("双击粘贴到当前应用")
        }
    }

    private var shouldTriggerPreview: Bool {
        autoPreview && viewModel.isPreviewModifierHeld
    }
}

#Preview {
    ClipboardVerticalView(items: [], viewModel: ClipboardViewModel())
}
