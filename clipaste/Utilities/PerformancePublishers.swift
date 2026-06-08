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

// MARK: - Simple Throttled Observer

/// 简单的节流观察者
final class ThrottledObserver<Value> {
    private var lastUpdate: Date = .distantPast
    private let interval: TimeInterval
    private var handler: ((Value) -> Void)?
    private var pendingValue: Value?
    
    init(interval: TimeInterval = 0.05) {
        self.interval = interval
    }
    
    func observe(_ handler: @escaping (Value) -> Void) {
        self.handler = handler
    }
    
    func update(_ value: Value) {
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) >= interval else {
            pendingValue = value
            return
        }
        
        lastUpdate = now
        handler?(value)
        
        if let pending = pendingValue {
            pendingValue = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
                self?.lastUpdate = Date()
                self?.handler?(pending)
            }
        }
    }
}

// MARK: - Batched Updater

/// 批量更新器：合并多次更新为单次
final class BatchedUpdater<Value> {
    private var currentValue: Value
    private var isScheduled = false
    private let interval: TimeInterval
    private var handler: ((Value) -> Void)?
    
    init(initial: Value, interval: TimeInterval = 0.016) {
        self.currentValue = initial
        self.interval = interval
    }
    
    func observe(_ handler: @escaping (Value) -> Void) {
        self.handler = handler
    }
    
    func update(_ value: Value) {
        currentValue = value
        
        guard !isScheduled else { return }
        isScheduled = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self = self else { return }
            self.isScheduled = false
            self.handler?(self.currentValue)
        }
    }
}
