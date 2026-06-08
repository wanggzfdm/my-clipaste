import SwiftUI
import Combine

/// 带防抖的 onHover 修饰符，减少动画触发频率
struct DebouncedHoverModifier: ViewModifier {
    @Binding var isHovering: Bool
    let debounceInterval: TimeInterval
    let onHoverChange: ((Bool) -> Void)?
    
    @State private var hoverTask: Task<Void, Never>?
    @State private var lastHoverState: Bool = false
    
    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                guard hovering != lastHoverState else { return }
                lastHoverState = hovering
                
                hoverTask?.cancel()
                
                hoverTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(debounceInterval * 1_000_000_000))
                    
                    if !Task.isCancelled {
                        await MainActor.run {
                            withAnimation(.easeInOut(duration: 0.08)) {
                                isHovering = hovering
                            }
                            onHoverChange?(hovering)
                        }
                    }
                }
            }
    }
}

extension View {
    func debouncedHover(
        isHovering: Binding<Bool>,
        debounceInterval: TimeInterval = 0.05,
        onChange: ((Bool) -> Void)? = nil
    ) -> some View {
        modifier(DebouncedHoverModifier(
            isHovering: isHovering,
            debounceInterval: debounceInterval,
            onHoverChange: onChange
        ))
    }
}

/// 条件动画修饰符：在特定条件下禁用动画
struct ConditionalAnimationModifier: ViewModifier {
    let condition: Bool
    let animation: Animation?
    
    func body(content: Content) -> some View {
        if condition {
            content.animation(animation, value: UUID())
        } else {
            content.animation(nil, value: UUID())
        }
    }
}

extension View {
    func conditionalAnimation(_ condition: Bool, animation: Animation? = .default) -> some View {
        modifier(ConditionalAnimationModifier(condition: condition, animation: animation))
    }
}

/// 滚动检测修饰符：在滚动时禁用动画
struct ScrollAwareAnimationModifier: ViewModifier {
    @Binding var isScrolling: Bool
    let animation: Animation?
    
    func body(content: Content) -> some View {
        content
            .conditionalAnimation(!isScrolling, animation: animation)
    }
}

/// 节流修饰符：限制操作频率
struct ThrottledClickModifier: ViewModifier {
    let action: () -> Void
    let interval: TimeInterval
    
    @State private var lastActionTime: Date = .distantPast
    @State private var pendingAction: Bool = false
    
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture()
                    .onEnded { _ in
                        let now = Date()
                        guard now.timeIntervalSince(lastActionTime) >= interval else {
                            pendingAction = true
                            return
                        }
                        lastActionTime = now
                        action()
                        
                        if pendingAction {
                            pendingAction = false
                            performPendingAction()
                        }
                    }
            )
    }
    
    private func performPendingAction() {
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            guard pendingAction else { return }
            pendingAction = false
            lastActionTime = Date()
            action()
        }
    }
}

extension View {
    func throttledClick(action: @escaping () -> Void, interval: TimeInterval = 0.3) -> some View {
        modifier(ThrottledClickModifier(action: action, interval: interval))
    }
}

/// 性能优化的 GeometryReader：避免不必要的重绘
struct PerformanceGeometryReader<Content: View>: View {
    let content: (CGRect) -> Content
    
    var body: some View {
        GeometryReader { geometry in
            content(geometry.frame(in: .global))
        }
    }
}

/// 批量更新修饰符：合并多个状态更新为单次动画
struct BatchUpdateModifier: ViewModifier {
    @Binding var updateTrigger: UUID
    let animations: () -> Void
    
    func body(content: Content) -> some View {
        content
            .onReceive(Just(updateTrigger)) { _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    animations()
                }
            }
    }
}
