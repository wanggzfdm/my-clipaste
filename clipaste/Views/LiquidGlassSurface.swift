import AppKit
import SwiftUI

/// Shared surface: the tray is transparent glass while cards retain opaque text-readable faces.
struct LiquidGlassSurface: View {
    let cornerRadius: CGFloat
    var isSelected = false
    @Environment(\.colorScheme) private var colorScheme

    private var cardFill: Color {
        colorScheme == .dark
            ? Color(.sRGB, white: 0.12, opacity: 0.94)
            : Color(.sRGB, white: 0.975, opacity: 0.94)
    }

    var body: some View {
        ZStack {
            if #available(macOS 26.0, *) {
                Color.clear
                    .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            } else {
                VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
            }

            cardFill

            // 仅保留顶部微弱高光提亮边缘，不再叠加底部黑色渐变：
            // 卡片本体已是 94% 不透明的可读底色，底部黑渐变会让文字区
            // 上亮下暗，观感发闷。
            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.08 : 0.28),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.72) : Color.white.opacity(colorScheme == .dark ? 0.26 : 0.52),
                    lineWidth: isSelected ? 1.5 : 0.8
                )
        }
    }
}

struct LiquidGlassPanelBackground: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            ZStack {
                Color.clear
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
                Color.white.opacity(0.06)
            }
        } else {
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .overlay(Color.white.opacity(0.03))
        }
    }
}
