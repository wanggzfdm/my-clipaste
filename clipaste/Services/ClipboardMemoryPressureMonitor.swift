import Foundation
import Dispatch

extension Notification.Name {
    static let clipboardMemoryPressure = Notification.Name("clipboardMemoryPressure")
}

/// Releases transient image/text/icon caches when the system reports memory pressure.
@MainActor
final class ClipboardMemoryPressureMonitor {
    static let shared = ClipboardMemoryPressureMonitor()

    private var source: DispatchSourceMemoryPressure?

    private init() {}

    func start() {
        guard source == nil else { return }

        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.handle(events: src.data)
        }
        src.resume()
        source = src
    }

    private func handle(events: DispatchSource.MemoryPressureEvent) {
        let isCritical = events.contains(.critical)
        NotificationCenter.default.post(
            name: .clipboardMemoryPressure,
            object: nil,
            userInfo: ["critical": isCritical]
        )

        // Always drop heavy caches under pressure. Warm history DTOs stay.
        ClipboardImagePipeline.shared.invalidateAll()
        ListRenderEngine.shared.invalidateAll()
        AppIconManager.shared.invalidateAll()
    }
}
