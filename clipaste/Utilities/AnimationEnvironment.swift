import SwiftUI

extension EnvironmentValues {
    var shouldDisableAnimations: Bool {
        get { self[ShouldDisableAnimationsKey.self] }
        set { self[ShouldDisableAnimationsKey.self] = newValue }
    }
}

private struct ShouldDisableAnimationsKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

struct DisableAnimationsModifier: ViewModifier {
    let shouldDisable: Bool

    func body(content: Content) -> some View {
        content
            .environment(\.shouldDisableAnimations, shouldDisable)
            .transaction { transaction in
                if shouldDisable {
                    transaction.disablesAnimations = true
                    transaction.animation = nil
                }
            }
    }
}

extension View {
    /// Pushes `shouldDisableAnimations` and also applies transaction-level animation kill.
    func disableAnimationsWhenScrolling(_ disable: Bool) -> some View {
        modifier(DisableAnimationsModifier(shouldDisable: disable))
    }
}
