import SwiftUI

enum SettingsPalette {
    private static let fallbackAccent = Color.settingsSidebarAccent

    static func updateAccent(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            fallbackAccent.opacity(0.92)
        default:
            fallbackAccent.opacity(0.88)
        }
    }

    static func sidebarSelectionAccent(_ accentColor: AppAccentColor, for _: ColorScheme) -> Color {
        accentColor.selectedContentColor
    }

    static func sidebarSelectionFill(_ accentColor: AppAccentColor, for _: ColorScheme) -> Color {
        accentColor.color
    }

    static func sidebarSelectionBorder(_ accentColor: AppAccentColor, for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            accentColor.color.opacity(0.82)
        default:
            accentColor.color.opacity(0.64)
        }
    }

    static func sidebarSelectionAccent(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            fallbackAccent.opacity(0.98)
        default:
            fallbackAccent.opacity(0.92)
        }
    }

    static func updateSurface(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            Color(.sRGB, red: 0.13, green: 0.18, blue: 0.22, opacity: 1.0)
        default:
            Color(.sRGB, red: 0.93, green: 0.96, blue: 0.97, opacity: 1.0)
        }
    }


    static func cardBackground(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            Color(.sRGB, red: 0.10, green: 0.12, blue: 0.15, opacity: 1.0)
        default:
            Color(.sRGB, red: 0.98, green: 0.98, blue: 0.98, opacity: 1.0)
        }
    }

    static func sidebarSelectionFill(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            fallbackAccent.opacity(0.26)
        default:
            fallbackAccent.opacity(0.18)
        }
    }

    static func sidebarSelectionBorder(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            fallbackAccent.opacity(0.42)
        default:
            fallbackAccent.opacity(0.30)
        }
    }
}
