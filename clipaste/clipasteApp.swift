import SwiftUI
import AppKit
import CoreServices
import KeyboardShortcuts
import SwiftData


@main
struct clipasteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var preferencesStore = AppPreferencesStore.shared
    @StateObject private var settingsViewModel = SettingsViewModel.shared
    @State private var screenPinViewModel = ScreenPinViewModel.shared
    private let runtimeStore = ClipboardRuntimeStore.shared
    private let appUpdateViewModel = AppUpdateViewModel.shared
    @AppStorage("appLanguage") private var appLanguage: AppLanguage = .auto

    var body: some Scene {
        // Register standard macOS Settings Window
        Settings {
            SettingsView()
                .environmentObject(preferencesStore)
                .environmentObject(settingsViewModel)
                .environment(runtimeStore)
                .environment(screenPinViewModel)
                .modelContainer(runtimeStore.container)
                .environment(\.locale, appLanguage.resolvedLocale)
                .environment(appUpdateViewModel)
        }
        .defaultSize(width: 900, height: 700)
        .windowResizability(.contentMinSize)
    }
}
