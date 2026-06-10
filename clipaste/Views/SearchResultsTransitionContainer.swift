import SwiftUI

struct SearchResultsTransitionToken: Equatable {
    let query: String
    let itemIDs: [UUID]
}

struct SearchResultsTransitionContainer<Content: View>: View {
    let isActive: Bool
    let token: SearchResultsTransitionToken
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSettlingContent = false
    @State private var transitionGeneration: UInt = 0

    var body: some View {
        content
            .onChange(of: token) { _, _ in
                runTransitionIfNeeded()
            }
            .onChange(of: isActive) { _, newValue in
                guard newValue == false else { return }
                transitionGeneration &+= 1
                isSettlingContent = false
            }
    }

    private var contentOpacity: Double {
        isSettlingContent ? 0.96 : 1
    }

    private var verticalOffset: CGFloat {
        guard !reduceMotion else { return 0 }
        return isSettlingContent ? 3 : 0
    }

    private var animation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.1)
            : .easeOut(duration: 0.16)
    }

    private func runTransitionIfNeeded() {
        transitionGeneration &+= 1
        isSettlingContent = false
    }
}
