import AppKit
import SwiftUI

struct AppIconView: View {
    let appBundleID: String?
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let icon = resolvedIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "macwindow")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }

    private var resolvedIcon: NSImage? {
        AppIconResolver.icon(for: appBundleID) ?? AppIconResolver.safariFallbackIcon
    }
}

private enum AppIconResolver {
    static let safariBundleIdentifier = "com.apple.Safari"

    static var safariFallbackIcon: NSImage? {
        icon(for: safariBundleIdentifier, allowFallback: false)
    }

    // 统一委托给 AppIconManager 的共享缓存(有 count/cost 上限),
    // 避免同一 bundleID 的多分辨率图标被两份 NSCache 各存一份。
    static func icon(for bundleIdentifier: String?, allowFallback: Bool = true) -> NSImage? {
        guard let bundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              bundleIdentifier.isEmpty == false else {
            return allowFallback ? safariFallbackIcon : nil
        }

        if let icon = AppIconManager.shared.getIcon(for: bundleIdentifier) {
            return icon
        }

        return allowFallback ? safariFallbackIcon : nil
    }
}
