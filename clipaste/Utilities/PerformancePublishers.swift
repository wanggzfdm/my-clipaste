import Combine
import SwiftUI

// MARK: - Performance Publisher Extensions

extension Publisher {
    /// 节流：在指定时间间隔内只发送最新值
    func throttleFor(interval: TimeInterval) -> Publishers.Throttle<Self, RunLoop> {
        throttle(for: .seconds(interval), scheduler: RunLoop.main, latest: true)
    }
    
    /// 防抖：在值停止变化后才发送
    func debounceFor(interval: TimeInterval) -> Publishers.Debounce<Self, RunLoop> {
        debounce(for: .seconds(interval), scheduler: RunLoop.main)
    }
}
