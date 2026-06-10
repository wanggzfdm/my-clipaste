import KeyboardShortcuts
import SwiftUI

struct ShortcutsSettingsView: View {
    @EnvironmentObject private var viewModel: SettingsViewModel

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
            ShortcutRecorderRow("Show / Hide Clipboard Panel", name: .toggleClipboardPanel)
        } header: {
            SettingsSectionHeader(title: "Global Shortcuts")
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
