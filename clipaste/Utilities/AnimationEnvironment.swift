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
    @Environment(\.shouldDisableAnimations) var shouldDisable
    
    func body(content: Content) -> some View {
        content.transaction { transaction in
            if shouldDisable {
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
        }
    }
}

extension View {
    func disableAnimationsWhenScrolling(_ disable: Bool) -> some View {
        modifier(DisableAnimationsModifier())
    }
}
