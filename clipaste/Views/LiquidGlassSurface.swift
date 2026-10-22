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

            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.16 : 0.42),
                    Color.clear,
                    Color.black.opacity(colorScheme == .dark ? 0.10 : 0.04)
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
