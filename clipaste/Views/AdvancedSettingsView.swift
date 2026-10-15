import SwiftUI

struct AdvancedSettingsView: View {
    @EnvironmentObject private var viewModel: SettingsViewModel
    @Environment(ClipboardRuntimeStore.self) private var runtimeStore
    @Environment(ScreenPinViewModel.self) private var screenPinViewModel
    @Environment(\.locale) private var locale
    @AppStorage("appAccentColor") private var appAccentColor: AppAccentColor = .defaultValue
    @AppStorage("enable_smart_groups") private var isSmartGroupsEnabled: Bool = true

    var body: some View {
        Form {
            coreInteractionSection
            interfaceSection
            migrationSection
        }
        .settingsPageChrome()
    }
}

// MARK: - Section 1: Interaction & Behavior

private extension AdvancedSettingsView {
    var coreInteractionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $viewModel.autoPasteToActiveApp) {
                    Text("Auto-Paste to Active App on Double-Click")
                }
                if viewModel.autoPasteToActiveApp {
                    Button("Open Accessibility Settings…", action: viewModel.openAccessibilitySettings)
                        .buttonStyle(.plain)
                        .tint(appAccentColor.color)
                        .font(.subheadline)
                        .foregroundStyle(appAccentColor.color)
                        .padding(.leading, 2)
                }
            }

            Toggle(isOn: $viewModel.moveToTopAfterPaste) {
                Text("Move Item to Top After Pasting")
            }

            Toggle(isOn: $viewModel.clearSearchOnPanelActivation) {
                Text("Clear Search When Opening Clipboard History")
            }

            Toggle(isOn: $viewModel.autoFocusFirstItemOnPanelActivation) {
                Text("Auto-Focus First Item When Opening Clipboard History")
            }

            Toggle(isOn: $viewModel.requireCmdToDelete) {
                Text("Require Cmd+Backspace to Delete")
            }

            Picker("Default Text Format", selection: $viewModel.pasteTextFormat) {
                ForEach(PasteTextFormat.allCases) { format in
                    Text(format.localizedTitle).tag(format)
                }
            }
        } header: {
            SettingsSectionHeader(title: "Interaction & Behavior")
        }
    }
}

// MARK: - Section 2: Interface

private extension AdvancedSettingsView {
    var interfaceSection: some View {
        @Bindable var screenPinViewModel = screenPinViewModel

        return Section {
            Toggle(isOn: $isSmartGroupsEnabled) {
                Text("Show Smart Groups")
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $screenPinViewModel.isEnabled) {
                    Text("Enable Screen Pinning")
                }

                Text("Press and hold the source app icon on an image history item, then drag it anywhere on the screen and release to pin the image.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Initial Pinned Image Size")
                    Spacer()
                    Text(screenPinViewModel.initialSizeScale, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: $screenPinViewModel.initialSizeScale,
                    in: ScreenPinViewModel.minimumInitialSizeScale...ScreenPinViewModel.maximumInitialSizeScale,
                    step: ScreenPinViewModel.initialSizeScaleStep
                )
            }
            .disabled(screenPinViewModel.isEnabled == false)

            Picker("Link Display Mode", selection: $viewModel.linkDisplayMode) {
                ForEach(ClipboardLinkDisplayMode.allCases) { mode in
                    Text(mode.localizedTitle).tag(mode)
                }
            }
        } header: {
            SettingsSectionHeader(title: "Interface")
        }
    }
}

// MARK: - Section 3: Migration Assistant

private extension AdvancedSettingsView {
    var migrationSection: some View {
        Section {
            MigrationView()
        } header: {
            SettingsSectionHeader(title: "Migration Assistant")
        }
    }
}


#Preview {
    AdvancedSettingsView()
        .environmentObject(SettingsViewModel())
        .environment(ClipboardRuntimeStore.shared)
        .environment(ScreenPinViewModel.shared)
}
