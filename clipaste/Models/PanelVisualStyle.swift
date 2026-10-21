import AppKit
import SwiftUI

/// Main-panel chrome family. Independent of system light/dark except that
/// `.paste` always runs under a forced dark appearance via `AppTheme`.
enum PanelVisualStyle: String, Sendable {
    case standard
    case paste
}

/// Numeric and color tokens for clipboard-panel shell, cards, and rows.
/// Standard values preserve the existing non-Paste appearance.
struct PanelChromeTokens {
    let style: PanelVisualStyle

    init(_ style: PanelVisualStyle) {
        self.style = style
    }

    static let panelCornerRadius: CGFloat = 25

    var horizontalPanelMaterial: NSVisualEffectView.Material {
        style == .paste ? .hudWindow : .popover
    }

    var usesLayeredHorizontalPanelBackground: Bool { style == .paste }
    var usesWindowBackgroundGlassForVertical: Bool { style == .paste }

    func panelCornerRadius(layout: AppLayoutMode) -> CGFloat {
        switch style {
        case .standard: (layout == .vertical || layout == .compact) ? 14 : 0
        case .paste: Self.panelCornerRadius
        }
    }

    var enablesSearchResultsTransition: Bool { style == .paste }
    var cardCornerRadius: CGFloat { style == .paste ? 16 : 16 }
    var cardSelectedBorderWidth: CGFloat { style == .paste ? 2.5 : 6 }
    var cardUnselectedBorderWidth: CGFloat { style == .paste ? 1 : 0.8 }
    var cardAlwaysCastsShadow: Bool { style == .standard }
    var cardSelectedShadowRadius: CGFloat { style == .paste ? 10 : 6 }
    var cardSelectedShadowY: CGFloat { style == .paste ? 4 : 3 }
    var cardIdleShadowRadius: CGFloat { style == .paste ? 14 : 0 }
    var cardIdleShadowY: CGFloat { style == .paste ? 7 : 0 }
    var cardContentHorizontalPadding: CGFloat { style == .paste ? 13 : 12 }
    var cardContentTopPadding: CGFloat { style == .paste ? 8 : 12 }
    var cardContentBottomPadding: CGFloat { style == .paste ? 13 : 12 }
    var cardHeaderTopRadius: CGFloat { cardCornerRadius }

    var cardSurfaceTint: Color {
        style == .paste ? Color(nsColor: .windowBackgroundColor).opacity(0.88) : Color(nsColor: .windowBackgroundColor)
    }
    var cardTopHighlightOpacity: Double { style == .paste ? 0.045 : 0 }
    var cardSelectedTintOpacity: Double { style == .paste ? 0.18 : 0 }
    var cardHoverBorderOpacity: Double { style == .paste ? 0.42 : 0.14 }
    var cardIdleBorderOpacity: Double { style == .paste ? 0.26 : 0.07 }
    var cardSelectedBorderOpacity: Double { style == .paste ? 0.92 : 0.85 }
    var cardSelectedShadowOpacity: Double { style == .paste ? 0.32 : 0.12 }
    var cardIdleShadowOpacity: Double { style == .paste ? 0.30 : 0 }

    var verticalRowCornerRadius: CGFloat { 12 }
    var verticalCompactRowCornerRadius: CGFloat { style == .paste ? 8 : 6 }
    var verticalSelectedFillOpacity: Double { style == .paste ? 0.14 : 0.12 }
    var verticalHoverFillOpacity: Double { style == .paste ? 0.60 : 1.0 }
    var verticalIdleFillOpacity: Double { style == .paste ? 0.52 : 0.6 }
    var verticalSelectedBorderOpacity: Double { style == .paste ? 0.82 : 1 }
    var verticalHoverBorderOpacity: Double { style == .paste ? 0.38 : 0.45 }
    var verticalIdleBorderOpacity: Double { style == .paste ? 0.12 : 0.12 }

    var emptySkeletonOpacity: Double { style == .paste ? 0.12 : 0.06 }
    var emptyHeaderOpacity: Double { style == .paste ? 0.11 : 0.08 }
}

extension AppTheme {
    var chrome: PanelChromeTokens {
        PanelChromeTokens(panelVisualStyle)
    }
}
