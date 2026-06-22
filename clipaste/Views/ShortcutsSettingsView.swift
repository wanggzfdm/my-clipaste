import KeyboardShortcuts
import SwiftUI

struct ShortcutsSettingsView: View {
    @EnvironmentObject private var viewModel: SettingsViewModel
    @AppStorage(GlobalSelectionTranslationService.isEnabledDefaultsKey)
    private var isGlobalSelectedTextTranslationEnabled = false

    var body: some View {
        Form {
            globalShortcutsSection
            panelShortcutsSection
            modifiersSection
            resetSection
        }
        .settingsPageChrome()
    }
}

// MARK: - Section 1: Global Shortcuts

private extension ShortcutsSettingsView {
    var globalShortcutsSection: some View {
        Section {
            ShortcutRecorderRow("显示 / 隐藏剪贴板面板", name: .toggleClipboardPanel)

            Toggle("启用全局选中文本翻译", isOn: $isGlobalSelectedTextTranslationEnabled)

            ShortcutRecorderRow("翻译选中文本", name: .translateSelectedText)
                .disabled(!isGlobalSelectedTextTranslationEnabled)
        } header: {
            SettingsSectionHeader(title: "全局快捷键")
        } footer: {
            SettingsSectionFooter {
                Text("开启后，可在其他 App 中选中文本并使用快捷键翻译。此功能需要辅助功能权限，并会在必要时临时复制选中文本后恢复剪贴板。")
            }
        }
    }
}

// MARK: - Section 2: Panel Shortcuts

private extension ShortcutsSettingsView {
    var panelShortcutsSection: some View {
        Section {
            PanelShortcutRecorderRow("Toggle Vertical Clipboard", action: .toggleVerticalClipboard)
            PanelShortcutRecorderRow("Next List", action: .nextList)
            PanelShortcutRecorderRow("Previous List", action: .prevList)
            PanelShortcutRecorderRow("Preview Selection", action: .previewSelection)
            PanelShortcutRecorderRow("Translate Preview", action: .translatePreviewSelection)
            PanelShortcutRecorderRow("Toggle Favorites for Selection", action: .toggleFavoriteSelection)
            PanelShortcutRecorderRow("Clear Clipboard History", action: .clearHistory)
        } header: {
            SettingsSectionHeader(title: "Panel Shortcuts")
        }
    }
}

// MARK: - Section 3: Modifier Keys

private extension ShortcutsSettingsView {
    var modifiersSection: some View {
        Section {
            ModifierPickerView(
                title: "Quick Paste",
                suffix: "+ 1…9",
                selection: $viewModel.quickPasteModifier
            )

            ModifierPickerView(
                title: "Plain Text Mode",
                suffix: "",
                selection: $viewModel.plainTextModifier
            )

        } header: {
            SettingsSectionHeader(title: "Modifier Keys")
        } footer: {
            SettingsSectionFooter {
                Text("Hold the quick paste modifier to reveal 1…9 shortcuts. Hold the plain text modifier while copying or pasting to strip formatting.")
            }
        }
    }
}

// MARK: - Section 4: Reset

private extension ShortcutsSettingsView {
    var resetSection: some View {
        Section {
            Button {
                KeyboardShortcuts.reset(.toggleClipboardPanel)
                KeyboardShortcuts.reset(.translateSelectedText)
                PanelShortcutStore.reset()
            } label: {
                Label("Reset Shortcuts to Defaults", systemImage: "arrow.counterclockwise")
            }
        }
    }
}

// MARK: - Shortcut Recorder Row

private struct ShortcutRecorderRow: View {
    let title: LocalizedStringKey
    @StateObject private var viewModel: ShortcutRecorderRowViewModel

    init(_ title: LocalizedStringKey, name: KeyboardShortcuts.Name) {
        self.title = title
        _viewModel = StateObject(wrappedValue: ShortcutRecorderRowViewModel(name: name))
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                shortcutRecorder

                if name.defaultShortcut != nil {
                    Button("Restore Default Shortcut", systemImage: "arrow.uturn.backward") {
                        viewModel.restoreDefault()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(!viewModel.canRestoreDefault)
                }
            }
        }
    }

    private var shortcutRecorder: some View {
        LocalizedShortcutRecorder(viewModel: viewModel)
    }

    private var name: KeyboardShortcuts.Name {
        viewModel.name
    }
}

private struct PanelShortcutRecorderRow: View {
    let title: LocalizedStringKey
    @StateObject private var viewModel: PanelShortcutRecorderRowViewModel

    init(_ title: LocalizedStringKey, action: PanelShortcutAction) {
        self.title = title
        _viewModel = StateObject(wrappedValue: PanelShortcutRecorderRowViewModel(action: action))
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                LocalizedPanelShortcutRecorder(viewModel: viewModel)

                Button("Restore Default Shortcut", systemImage: "arrow.uturn.backward") {
                    viewModel.restoreDefault()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(!viewModel.canRestoreDefault)
            }
        }
    }
}

#Preview {
    ShortcutsSettingsView()
        .environmentObject(SettingsViewModel())
}
