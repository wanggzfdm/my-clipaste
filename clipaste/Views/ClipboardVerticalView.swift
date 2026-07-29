import SwiftUI

struct ClipboardVerticalView: View {
    let items: [ClipboardItem]
    @ObservedObject var viewModel: ClipboardViewModel
    @AppStorage("singleClickPaste") private var singleClickPaste = true

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 16) {
                ForEach(items) { item in
                    ClipboardCardView(
                        item: item,
                        viewModel: viewModel,
                        isSelected: viewModel.selectedItemIDs.contains(item.id),
                        searchHighlight: viewModel.activeSearchQuery,
                        isQuickPasteModifierHeld: viewModel.isQuickPasteModifierHeld,
                        isAIEnabled: viewModel.aiSettingsViewModel.isAIEnabled
                    )
                    .equatable()
                        .help(pasteHelpText)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pasteHelpText: Text {
        if singleClickPaste {
            Text("单击复制，双击粘贴到当前应用")
        } else {
            Text("双击粘贴到当前应用")
        }
    }

}

#Preview {
    ClipboardVerticalView(items: [], viewModel: ClipboardViewModel())
}
