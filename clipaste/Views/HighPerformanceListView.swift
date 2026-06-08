import SwiftUI
import AppKit

/// 高性能列表视图占位符
/// 当前版本使用标准的 ScrollView + LazyVStack
/// 未来可以替换为 NSCollectionView 实现以获得更好的性能
struct HighPerformanceListView<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let itemHeight: CGFloat
    let itemSpacing: CGFloat
    let content: (Item) -> Content
    
    init(
        items: [Item],
        itemHeight: CGFloat = 76,
        itemSpacing: CGFloat = 8,
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.items = items
        self.itemHeight = itemHeight
        self.itemSpacing = itemSpacing
        self.content = content
    }
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: itemSpacing) {
                ForEach(items) { item in
                    content(item)
                        .frame(height: itemHeight)
                }
            }
        }
    }
}

/// 节流滚动处理器
final class ThrottledScrollHandler {
    private var lastScrollTime: Date = .distantPast
    private let interval: TimeInterval
    private var pendingHandler: (() -> Void)?
    
    init(interval: TimeInterval = 0.016) {
        self.interval = interval
    }
    
    func handleScroll(frame: CGRect, handler: @escaping () -> Void) {
        let now = Date()
        guard now.timeIntervalSince(lastScrollTime) >= interval else {
            pendingHandler = handler
            return
        }
        
        lastScrollTime = now
        handler()
        
        if let pending = pendingHandler {
            pendingHandler = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
                self.lastScrollTime = Date()
                pending()
            }
        }
    }
}
