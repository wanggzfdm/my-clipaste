import AppKit
import Foundation
import SwiftUI

extension ClipboardItem {
    /// 卡片角标等内容类型文案（与筛选标签共用同一套 String Catalog 键）。
    @MainActor
    func typeBadgeTitle() -> LocalizedStringResource {
        switch contentType {
        case .text: return LocalizedStringResource("Smart Filter Text")
        case .image: return LocalizedStringResource("Smart Filter Image")
        case .fileURL: return LocalizedStringResource("Smart Filter File")
        case .color: return LocalizedStringResource("Smart Filter Color")
        case .link: return LocalizedStringResource("Smart Filter Link")
        case .code: return LocalizedStringResource("Smart Filter Code")
        }
    }

    /// 卡片 header 的类型色：按内容类型区分色相，让列表有节奏感。
    /// 年轻化荧光色板：整体高亮度、窄幅渐变，底端不再压暗，
    /// 保证 header 全程鲜活。
    var typeHeaderColor: Color { typeHeaderGradient.top }

    /// header 标题/时间戳文字色：header 亮端向白色高比例混合，
    /// 接近白但带一丝 header 色温，与渐变底色融合。
    var typeIconChipColor: Color {
        let base = typeHeaderGradient.top
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(AppKit)
        NSColor(base).usingColorSpace(.sRGB)!.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        let mix: CGFloat = 0.88
        return Color(.sRGB,
                     red: r + (1 - r) * mix,
                     green: g + (1 - g) * mix,
                     blue: b + (1 - b) * mix,
                     opacity: 1)
    }

    var typeHeaderGradient: (top: Color, bottom: Color) {
        switch contentType {
        case .text:
            return (Color(.sRGB, red: 0.05, green: 0.62, blue: 1.00, opacity: 1),
                    Color(.sRGB, red: 0.25, green: 0.42, blue: 1.00, opacity: 1))  // 电光蓝 → 亮群青
        case .link:
            return (Color(.sRGB, red: 0.00, green: 0.87, blue: 0.74, opacity: 1),
                    Color(.sRGB, red: 0.00, green: 0.66, blue: 0.62, opacity: 1))  // 荧光薄荷 → 翠青
        case .image:
            return (Color(.sRGB, red: 0.72, green: 0.42, blue: 1.00, opacity: 1),
                    Color(.sRGB, red: 0.55, green: 0.24, blue: 0.95, opacity: 1))  // 亮紫罗兰 → 电紫
        case .fileURL:
            return (Color(.sRGB, red: 1.00, green: 0.72, blue: 0.15, opacity: 1),
                    Color(.sRGB, red: 1.00, green: 0.48, blue: 0.20, opacity: 1))  // 杏橙 → 珊瑚橙
        case .code:
            return (Color(.sRGB, red: 0.30, green: 0.74, blue: 1.00, opacity: 1),
                    Color(.sRGB, red: 0.15, green: 0.53, blue: 0.95, opacity: 1))  // 晴空蓝 → 亮海蓝
        case .color:
            return (Color(.sRGB, red: 1.00, green: 0.50, blue: 0.70, opacity: 1),
                    Color(.sRGB, red: 0.98, green: 0.26, blue: 0.55, opacity: 1))  // 樱粉 → 艳玫红
        }
    }

    var groupId: String? {
        groupIDs.first
    }

    var trimmedCustomTitle: String? {
        let normalized = customTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, normalized.isEmpty == false else {
            return nil
        }
        return normalized
    }

    var hasCustomTitle: Bool {
        trimmedCustomTitle != nil
    }

    var imagePixelSize: CGSize? {
        guard let imagePixelWidth, let imagePixelHeight else { return nil }
        guard imagePixelWidth > 0, imagePixelHeight > 0 else { return nil }
        return CGSize(width: imagePixelWidth, height: imagePixelHeight)
    }

    var isScreenPinEligible: Bool {
        contentType == .image || (contentType == .fileURL && fileRepresentsImage)
    }

    nonisolated static func normalizedGroupIDs(primaryGroupID: String?, groupIDs: [String]) -> [String] {
        var result: [String] = []

        if let primaryGroupID, !primaryGroupID.isEmpty {
            result.append(primaryGroupID)
        }

        for id in groupIDs where !id.isEmpty && result.contains(id) == false {
            result.append(id)
        }

        return result
    }
}
