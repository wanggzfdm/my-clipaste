import AppKit
import SwiftUI

struct AboutSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appAccentColor") private var appAccentColor: AppAccentColor = .defaultValue
    @AppStorage("lastOpenedOfficialWebsiteVersion") private var lastOpenedOfficialWebsiteVersion = ""
    private let telegramURL = URL(string: "https://t.me/clipaste")!
    private let githubURL = URL(string: "https://github.com/gangz1o/Clipaste")!
    private let websiteURL = URL(string: "https://clipaste.com")!
    private let iOSAppStoreURL = URL(string: "https://apps.apple.com/us/app/clipaste-%E5%89%AA%E8%B4%B4%E6%9D%BF%E9%94%AE%E7%9B%98/id6768657055")!
    private let privacyPolicyURL = URL(string: "https://legal.clipaste.com/?page=privacy")!
    private let termsOfServiceURL = URL(string: "https://legal.clipaste.com/?page=terms")!

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            brandSection

            Form {
                versionSection
                linksSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .settingsScrollChromeHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Brand Header

private extension AboutSettingsView {
    var brandSection: some View {
        VStack(spacing: 10) {
            Image(nsImage: appIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .clipShape(.rect(cornerRadius: 16))
                .shadow(color: .black.opacity(0.10), radius: 10, y: 5)

            Text(AppMetadata.displayName)
                .font(.system(size: 24, weight: .semibold))
                .tracking(-0.3)

            HStack(spacing: 8) {
                brandIconLink(assetName: "telegram", title: "Telegram", destination: telegramURL)
                brandSeparator
                brandIconLink(assetName: "github", title: "GitHub", destination: githubURL)
                brandSeparator

                HStack(spacing: 4) {
                    Text("Version")
                    Text(verbatim: AppMetadata.displayVersion)
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
    }

    var appIconImage: NSImage {
        NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
    }

    var brandSeparator: some View {
        Text(verbatim: "|")
            .font(.callout)
            .foregroundStyle(.tertiary)
    }

    func brandIconLink(assetName: String, title: LocalizedStringKey, destination: URL) -> some View {
        Link(destination: destination) {
            Image(assetName)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .help(Text(title))
    }
}

// MARK: - Version

private extension AboutSettingsView {
    var versionSection: some View {
        Section {
            LabeledContent("Current Version") {
                Text(verbatim: AppMetadata.displayVersion)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            SettingsSectionHeader(title: "About")
        }
    }
}

// MARK: - Links

private extension AboutSettingsView {
    var linksSection: some View {
        Section {
            Link(destination: iOSAppStoreURL) {
                linkRow(title: "Get iOS Version", systemImage: "iphone")
            }
            .buttonStyle(.plain)

            Button(action: openOfficialWebsite) {
                linkRow(
                    title: "Official Website",
                    systemImage: "globe",
                    showsNewBadge: shouldShowOfficialWebsiteNewBadge
                )
            }
            .buttonStyle(.plain)

            Button(action: sendFeedback) {
                linkRow(title: "Send Feedback", systemImage: "paperplane")
            }
            .buttonStyle(.plain)

            Link(destination: privacyPolicyURL) {
                linkRow(title: "Privacy Policy", systemImage: "lock.doc")
            }
            .buttonStyle(.plain)

            Link(destination: termsOfServiceURL) {
                linkRow(title: "Terms of Service", systemImage: "doc.text")
            }
            .buttonStyle(.plain)
        } header: {
            SettingsSectionHeader(title: "About & Support")
        }
    }

    var shouldShowOfficialWebsiteNewBadge: Bool {
        lastOpenedOfficialWebsiteVersion != AppMetadata.displayVersion
    }

    func linkRow(
        title: LocalizedStringKey,
        systemImage: String,
        showsNewBadge: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(title)
                .font(.body)
                .foregroundStyle(.primary)

            if showsNewBadge {
                newBadge
            }

            Spacer()

            Image(systemName: "arrow.up.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    var newBadge: some View {
        Text("New")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(appAccentColor.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(appAccentColor.color.opacity(colorScheme == .dark ? 0.18 : 0.10))
                    .overlay {
                        Capsule()
                            .stroke(appAccentColor.color.opacity(colorScheme == .dark ? 0.35 : 0.18), lineWidth: 1)
                    }
            }
    }

    func openOfficialWebsite() {
        lastOpenedOfficialWebsiteVersion = AppMetadata.displayVersion
        NSWorkspace.shared.open(websiteURL)
    }

    func sendFeedback() {
        guard let url = URL(string: "mailto:your_email@example.com?subject=Clipaste%20Feedback") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

#Preview {
    AboutSettingsView()
}
