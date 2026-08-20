import AppKit
import SwiftUI

/// Main-panel chrome family. Independent of system light/dark except that
/// `.paste` always runs under a forced dark appearance via `AppTheme`.
enum PanelVisualStyle: String, Sendable {
    case standard
    case paste
}

/// Numeric / material tokens for the clipboard panel shell and cards.
/// `standard` mirrors current 2.2.10 hard-coded values so default pixels stay put.
struct PanelChromeTokens {
    let style: PanelVisualStyle

    init(_ style: PanelVisualStyle) {
        self.style = style
    }

    // MARK: - Panel shell

    var horizontalPanelMaterial: NSVisualEffectView.Material {
        switch style {
        case .standard:
            return .popover
        case .paste:
            return .hudWindow
        }
    }

    var usesLayeredHorizontalPanelBackground: Bool {
        style == .paste
    }

    var usesWindowBackgroundGlassForVertical: Bool {
        style == .paste
    }

    func panelCornerRadius(layout: AppLayoutMode) -> CGFloat {
        switch style {
        case .standard:
            return (layout == .vertical || layout == .compact) ? 14 : 0
        case .paste:
            return (layout == .vertical || layout == .compact) ? 14 : 26
        }
    }

    var enablesSearchResultsTransition: Bool {
        style == .paste
    }

    // MARK: - Horizontal card

    var cardCornerRadius: CGFloat {
        switch style {
        case .standard:
            return 16
        case .paste:
            return 25
        }
    }

    var cardSelectedBorderWidth: CGFloat {
        switch style {
        case .standard:
            return 6
        case .paste:
            return 1.5
        }
    }

    var cardUnselectedBorderWidth: CGFloat {
        0.8
    }

    var cardAlwaysCastsShadow: Bool {
        style == .standard
    }

    var cardSelectedShadowRadius: CGFloat {
        switch style {
        case .standard:
            return 6
        case .paste:
            return 10
        }
    }

    var cardSelectedShadowY: CGFloat {
        switch style {
        case .standard:
            return 3
        case .paste:
            return 4
        }
    }

    var cardContentHorizontalPadding: CGFloat {
        switch style {
        case .standard:
            return 12
        case .paste:
            return 13
        }
    }

    var cardContentTopPadding: CGFloat {
        switch style {
        case .standard:
            return 12
        case .paste:
            return 8
        }
    }

    var cardContentBottomPadding: CGFloat {
        switch style {
        case .standard:
            return 12
        case .paste:
            return 13
        }
    }

    var cardHeaderTopRadius: CGFloat {
        cardCornerRadius
    }

    // MARK: - Vertical row

    var verticalRowCornerRadius: CGFloat {
        // compact uses 6, regular 12 — caller still passes isCompact
        switch style {
        case .standard:
            return 12
        case .paste:
            return 12
        }
    }

    var verticalSelectedFillOpacity: Double {
        switch style {
        case .standard:
            return 0.12
        case .paste:
            return 0.14
        }
    }
}

extension AppTheme {
    var chrome: PanelChromeTokens {
        PanelChromeTokens(panelVisualStyle)
    }
}
