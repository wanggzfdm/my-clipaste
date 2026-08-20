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
            .opacity(contentOpacity)
            .offset(y: verticalOffset)
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

    /// 搜索结果集变化时:先无动画地压到轻微下沉+降透明,
    /// 下一个 runloop 再动画回落,形成一次短促的 settle 过渡。
    private func runTransitionIfNeeded() {
        guard isActive else { return }

        transitionGeneration &+= 1
        let generation = transitionGeneration

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isSettlingContent = true
        }

        DispatchQueue.main.async {
            guard generation == transitionGeneration else { return }
            withAnimation(animation) {
                isSettlingContent = false
            }
        }
    }
}
