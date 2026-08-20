import AppKit
import SwiftUI
import SwiftData

/// ClipboardPanelManager is responsible for managing the floating clipboard history panel.
/// It uses a borderless panel that follows the mouse's screen and presents in front of the Dock.
@MainActor
class ClipboardPanelManager {
    static let shared = ClipboardPanelManager()
    private static let panelLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)

    private(set) var panel: ClipboardPanel?
    private var eventMonitor: Any?
    private var layoutObserver: Any?
    private var previewObserver: Any?
    private var pinObserver: Any?
    private var forceHideObserver: Any?

    /// Additional width to add when preview panel is active
    private let previewExpandedWidth: CGFloat = 380

    /// 记录呼出面板前正在活跃的 App（如微信、Safari），用于关闭面板时精准归还焦点
    private var previousActiveApp: NSRunningApplication?

    /// Whether the panel is pinned (won't auto-dismiss on outside click).
    private var isPinned: Bool = UserDefaults.standard.bool(forKey: "isPanelPinned")

    /// Indicates whether the panel is currently visible to the user.
    private(set) var isVisible: Bool = false

    /// 面板正在显示模态对话框（如 .alert）时，阻止外部点击隐藏面板。
    /// 由 View 层在弹出/收起对话框时设置。
    var suppressHide: Bool = false

    private struct ContentPresentationAnimation {
        let layer: CALayer
        let fromTransform: CATransform3D
        let duration: CFTimeInterval
        let timing: CAMediaTimingFunction
    }

    private struct BottomPresentationAnimation {
        let layer: CALayer
        let fromTransform: CATransform3D
        let duration: CFTimeInterval
        let timing: CAMediaTimingFunction
    }
    private init() {
        setupPanel()
        setupLayoutObserver()
        setupPreviewObserver()
        setupPinObserver()
        setupForceHideObserver()
    }

    func preparePanelIfNeeded() {
        if panel == nil {
            setupPanel()
        }
    }

    private func setupPanel() {
        let styleMask: NSWindow.StyleMask = [.borderless]

        let panel = ClipboardPanel(
            contentRect: .zero,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.alphaValue = 0.0

        panel.level = Self.panelLevel
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let hostingController = NSHostingController(
            rootView: ClipboardPanelRootView()
                .environmentObject(AppPreferencesStore.shared)
                .environment(ClipboardRuntimeStore.shared)
                .environment(ScreenPinViewModel.shared)
        )
        hostingController.sizingOptions = []   // 禁止 SwiftUI 内容撑大面板，由 setFrame 控制
        // NSHostingView defaults can paint an opaque backdrop and kill behind-window glass.
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        if #available(macOS 14.0, *) {
            // Best-effort: older SDKs still benefit from the layer clear above.
            (hostingController.view as NSView).layer?.isOpaque = false
        }
        panel.contentViewController = hostingController
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor

        self.panel = panel
    }

    // MARK: - Observers

    private func setupLayoutObserver() {
        layoutObserver = NotificationCenter.default.addObserver(
            forName: .clipboardLayoutModeChanged,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self, let layout = notification.object as? AppLayoutMode else { return }

            let applyLayoutUpdate = {
                MainActor.assumeIsolated {
                    self.updatePanelSize(layout: layout, animated: false)
                }
            }

            if Thread.isMainThread {
                applyLayoutUpdate()
            } else {
                DispatchQueue.main.async(execute: applyLayoutUpdate)
            }
        }
    }

    private func setupPinObserver() {
        pinObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("TogglePinStatus"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let pinned = notification.object as? Bool else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPinned = pinned
                // 固定时保持原有层级（dockWindow+1），始终在 Dock 之上
                // 注意：.floating (level 3) 远低于 Dock 层级，不可使用
                self.panel?.level = Self.panelLevel
            }
        }
    }

    private func setupPreviewObserver() {
        previewObserver = NotificationCenter.default.addObserver(
            forName: .clipboardPreviewPanelChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }

            let applyPreviewUpdate = {
                MainActor.assumeIsolated {
                    let layout = AppLayoutMode(
                        rawValue: UserDefaults.standard.string(forKey: "clipboardLayout")
                            ?? AppLayoutMode.horizontal.rawValue
                    ) ?? .horizontal
                    self.updatePanelSize(layout: layout, animated: false)
                }
            }

            if Thread.isMainThread {
                applyPreviewUpdate()
            } else {
                DispatchQueue.main.async(execute: applyPreviewUpdate)
            }
        }
    }

    private func setupForceHideObserver() {
        forceHideObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("HidePanelForce"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.forceHidePanel()
            }
        }
    }

    // MARK: - Panel Size

    /// Returns the target frame for vertical mode, applying the user-selected follow mode
    /// and strict screen-edge collision detection.
    private func verticalFrame(on screen: NSScreen) -> NSRect {
        let sf = screen.visibleFrame
        
        // Determine if preview panel is enabled
        let previewMode = PreviewPanelMode.resolved()
        let isPreviewEnabled = previewMode == .enabled
        
        let baseWidth: CGFloat = 360
        let width: CGFloat = isPreviewEnabled ? baseWidth + previewExpandedWidth : baseWidth
        let height: CGFloat = 700
        let modeRaw = UserDefaults.standard.string(forKey: "verticalFollowMode") ?? VerticalFollowMode.mouse.rawValue
        let mode = VerticalFollowMode(rawValue: modeRaw) ?? .mouse

        switch mode {
        case .statusBar:
            // Top-right safe area, just below the menu bar
            let x = sf.maxX - width - 12
            let y = sf.maxY - height - 12
            return NSRect(x: x, y: y, width: width, height: height)

        case .mouse:
            let mouseLoc = NSEvent.mouseLocation
            var x = mouseLoc.x - width / 2
            var y = mouseLoc.y - height / 2
            // Edge collision clamping
            if x < sf.minX { x = sf.minX + 12 }
            if x + width > sf.maxX { x = sf.maxX - width - 12 }
            if y < sf.minY { y = sf.minY + 12 }
            if y + height > sf.maxY { y = sf.maxY - height - 12 }
            return NSRect(x: x, y: y, width: width, height: height)

        case .lastPosition:
            let current = panel?.frame ?? .zero
            // Cold-start fallback: center on screen
            if current.minX == 0 && current.minY == 0 {
                let x = sf.minX + (sf.width - width) / 2
                let y = sf.minY + (sf.height - height) / 2
                return NSRect(x: x, y: y, width: width, height: height)
            }
            // Preserve last origin but enforce correct size
            return NSRect(x: current.minX, y: current.minY, width: width, height: height)
        }
    }

    /// Returns the target frame for the given layout, using the correct positioning strategy.
    private func panelFrame(for layout: AppLayoutMode, on screen: NSScreen) -> NSRect {
        switch layout {
        case .horizontal:
            let full = screen.frame          // 使用完整屏幕帧，覆盖 Dock 栏
            let height: CGFloat = 320
            return NSRect(x: full.minX, y: full.minY, width: full.width, height: height)
        case .vertical, .compact:
            return verticalFrame(on: screen)
        }
    }

    private func updatePanelSize(layout: AppLayoutMode, animated: Bool) {
        guard let panel, let screen = screenContainingMouse() ?? NSScreen.main else { return }
        let target = panelFrame(for: layout, on: screen)

        // Synchronously batch the frame change and the subsequent AppKit redraw into one
        // flush. This avoids a transient frame where SwiftUI has switched layout but the
        // panel is still rendering at the previous size.
        panel.disableScreenUpdatesUntilFlush()
        panel.setFrame(target, display: false)

        // 竖版浮窗保留阴影；Paste 风格横版也保留阴影（fork 2.1.5 始终 hasShadow=true）
        // 标准横版贴底仍关阴影，避免顶部边框线。
        let prefersPasteGlass = isPasteThemeActive
        panel.hasShadow = prefersPasteGlass || layout == .vertical || layout == .compact
        applyPanelMovability(for: layout, panel: panel)

        DispatchQueue.main.async { [weak panel] in
            panel?.displayIfNeeded()
        }
    }

    // MARK: - Show / Hide

    /// Toggles the visibility of the clipboard panel.
    func togglePanel() {
        if isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    /// Shows the panel sized for the current layout mode, then animates it in.
    func showPanel() {
        guard !isVisible, let panel else { return }

        // 0. 拍照留底：在呼出面板之前，记下当前正活跃的 App
        //    必须在 activate / makeKeyAndOrderFront 之前调用，否则 frontmostApplication 会变成自己
        previousActiveApp = NSWorkspace.shared.frontmostApplication

        let layout = AppLayoutMode(
            rawValue: UserDefaults.standard.string(forKey: "clipboardLayout") ?? AppLayoutMode.horizontal.rawValue
        ) ?? .horizontal
        let screen = screenContainingMouse() ?? NSScreen.main

        applyPanelMovability(for: layout, panel: panel)
        let prefersPasteGlass = isPasteThemeActive
        panel.hasShadow = prefersPasteGlass || layout == .vertical || layout == .compact

        let visibleFrame = panelFrame(for: layout, on: screen ?? NSScreen.main!)

        // Paste 风格：fork 2.1.5 内容层滑入/淡入；标准主题保留窗口 frame 滑入。
        if prefersPasteGlass {
            presentPanelWithPasteAnimation(panel: panel, layout: layout, visibleFrame: visibleFrame)
        } else {
            presentPanelWithStandardAnimation(panel: panel, layout: layout, visibleFrame: visibleFrame)
        }
    }

    private var isPasteThemeActive: Bool {
        UserDefaults.standard.string(forKey: "appTheme") == AppTheme.paste.rawValue
    }

    /// Upstream 2.2.10 window-frame slide + fade.
    private func presentPanelWithStandardAnimation(
        panel: ClipboardPanel,
        layout: AppLayoutMode,
        visibleFrame: NSRect
    ) {
        let hiddenFrame: NSRect
        if layout == .horizontal {
            hiddenFrame = NSRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY - 20,
                width: visibleFrame.width,
                height: visibleFrame.height
            )
        } else {
            hiddenFrame = visibleFrame
        }

        panel.setFrame(hiddenFrame, display: true)
        panel.alphaValue = 0.0

        panel.makeKeyAndOrderFront(nil)
        panel.becomeFirstResponder()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(visibleFrame, display: true)
            panel.animator().alphaValue = 1.0
        }) { [weak self] in
            Task { @MainActor [weak self] in
                self?.completePresentation()
            }
        }
    }

    /// Fork 2.1.5 presentation: content-layer bottom slide / float, short vertical fade.
    private func presentPanelWithPasteAnimation(
        panel: ClipboardPanel,
        layout: AppLayoutMode,
        visibleFrame: NSRect
    ) {
        let presentationStyle = horizontalPanelPresentationStyle()
        let shouldReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let bottomAnimation = layout == .horizontal && presentationStyle == .bottomSlide && !shouldReduceMotion
            ? prepareBottomPresentationAnimation(for: panel)
            : nil
        let contentAnimation = presentationStyle == .float || shouldReduceMotion
            ? prepareContentPresentationAnimation(for: panel, layout: layout)
            : nil

        panel.setFrame(visibleFrame, display: true)
        panel.alphaValue = layout == .horizontal ? 1.0 : 0.0

        // ⚠️ 不调用 NSApp.activate — 保持目标 App 焦点，便于 Cmd+V。
        panel.makeKeyAndOrderFront(nil)
        panel.becomeFirstResponder()

        switch layout {
        case .horizontal:
            if presentationStyle == .bottomSlide, !shouldReduceMotion {
                runBottomPresentationAnimation(bottomAnimation) { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.completePresentation()
                    }
                }
            } else {
                runContentPresentationAnimation(contentAnimation) { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.completePresentation()
                    }
                }
            }
        case .vertical, .compact:
            let finishPresentation: () -> Void = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.completePresentation()
                }
            }

            if shouldReduceMotion {
                panel.alphaValue = 1.0
                finishPresentation()
            } else {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.1
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.88, 0.20, 1.0)
                    panel.animator().alphaValue = 1.0
                }, completionHandler: finishPresentation)
            }
        }
    }

    private func completePresentation() {
        isVisible = true
        setupEventMonitor()
    }

    private func prepareContentPresentationAnimation(
        for panel: ClipboardPanel,
        layout: AppLayoutMode
    ) -> ContentPresentationAnimation? {
        guard layout == .horizontal, let contentView = panel.contentView else {
            return nil
        }

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            return nil
        }

        contentView.wantsLayer = true
        guard let layer = contentView.layer else {
            return nil
        }

        let initialOffset: CGFloat = 5
        let duration: CFTimeInterval = 0.1
        let timing = CAMediaTimingFunction(controlPoints: 0.22, 0.88, 0.20, 1.0)
        let fromTransform = CATransform3DMakeTranslation(0, initialOffset, 0)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = fromTransform
        CATransaction.commit()

        return ContentPresentationAnimation(
            layer: layer,
            fromTransform: fromTransform,
            duration: duration,
            timing: timing
        )
    }

    private func runContentPresentationAnimation(
        _ animation: ContentPresentationAnimation?,
        completion: @escaping () -> Void
    ) {
        guard let animation else {
            completion()
            return
        }

        let layer = animation.layer

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        CATransaction.commit()

        let transformAnimation = CABasicAnimation(keyPath: "transform")
        transformAnimation.fromValue = NSValue(caTransform3D: animation.fromTransform)
        transformAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)

        let group = CAAnimationGroup()
        group.animations = [transformAnimation]
        group.duration = animation.duration
        group.timingFunction = animation.timing
        group.isRemovedOnCompletion = true

        layer.add(group, forKey: "horizontalPanelPresentation")

        DispatchQueue.main.asyncAfter(deadline: .now() + animation.duration) {
            completion()
        }
    }

    private func prepareBottomPresentationAnimation(for panel: ClipboardPanel) -> BottomPresentationAnimation? {
        guard let contentView = panel.contentView else {
            return nil
        }

        contentView.wantsLayer = true
        guard let layer = contentView.layer else {
            return nil
        }

        let fromTransform = CATransform3DMakeTranslation(0, -54, 0)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "horizontalPanelBottomPresentation")
        layer.opacity = 1.0
        layer.transform = fromTransform
        CATransaction.commit()

        return BottomPresentationAnimation(
            layer: layer,
            fromTransform: fromTransform,
            duration: 0.1,
            timing: CAMediaTimingFunction(controlPoints: 0.18, 0.92, 0.20, 1.0)
        )
    }

    private func runBottomPresentationAnimation(
        _ animation: BottomPresentationAnimation?,
        completion: @escaping () -> Void
    ) {
        guard let animation else {
            completion()
            return
        }

        let layer = animation.layer

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        CATransaction.commit()

        let transformAnimation = CABasicAnimation(keyPath: "transform")
        transformAnimation.fromValue = NSValue(caTransform3D: animation.fromTransform)
        transformAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        transformAnimation.duration = animation.duration
        transformAnimation.timingFunction = animation.timing
        transformAnimation.isRemovedOnCompletion = true

        layer.add(transformAnimation, forKey: "horizontalPanelBottomPresentation")

        DispatchQueue.main.asyncAfter(deadline: .now() + animation.duration) {
            completion()
        }
    }

    private func horizontalPanelPresentationStyle() -> HorizontalPanelPresentationStyle {
        let storedValue = UserDefaults.standard.string(forKey: "horizontalPanelPresentationStyle")
        return storedValue.flatMap(HorizontalPanelPresentationStyle.init(rawValue:))
            ?? HorizontalPanelPresentationStyle.defaultValue
    }

    private func applyPanelMovability(for layout: AppLayoutMode, panel: ClipboardPanel) {
        panel.isMovableByWindowBackground = false
        panel.isMovable = layout == .vertical || layout == .compact
    }

    /// Hides the clipboard panel — intercepted when the panel is pinned or showing a modal dialog.
    func hidePanel() {
        guard isVisible else { return }
        if isPinned { return } // 图钉固定时，拦截隐藏指令
        if suppressHide { return } // 模态对话框（如删除确认 alert）激活时，拦截隐藏指令
        executeHide()
    }

    /// Hides only the clipboard panel, keeping the currently active Clipaste window interactive.
    func hidePanelPreservingActiveApp() {
        guard isVisible else { return }
        if isPinned { return }
        if suppressHide { return }
        executeHide(restorePreviousActiveApp: false)
    }

    /// Force-hides the panel regardless of pin state (used by paste/settings/about).
    func forceHidePanel() {
        guard isVisible else { return }
        executeHide()
    }

    private func executeHide(restorePreviousActiveApp: Bool = true) {
        guard let panel = panel else { return }
        panel.contentView?.layer?.removeAnimation(forKey: "horizontalPanelBottomPresentation")
        panel.contentView?.layer?.removeAnimation(forKey: "horizontalPanelPresentation")
        panel.contentView?.layer?.transform = CATransform3DIdentity
        removeEventMonitor()
        panel.orderOut(nil)
        panel.resignKey()
        isVisible = false

        // 将焦点精准归还给呼出面板前的 App（保证 Cmd+V 粘贴命中目标窗口）
        if restorePreviousActiveApp, let app = previousActiveApp, !app.isTerminated {
            app.activate()
        }
        previousActiveApp = nil
    }

    private func dismissPanelOnly() {
        executeHide()
    }


    private func screenContainingMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
    }

    private func hasOtherActiveWindows() -> Bool {
        guard let panel else { return false }
        return NSApplication.shared.windows.filter(\.isVisible).contains { $0 !== panel }
    }

    // MARK: - Event Monitoring

    private func setupEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isVisible else { return }
                // 始终走 hidePanel()，内部会检查图钉状态
                self.hidePanel()
            }
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

private struct ClipboardPanelRootView: View {
    @EnvironmentObject private var preferencesStore: AppPreferencesStore
    @Environment(ClipboardRuntimeStore.self) private var runtimeStore
    @AppStorage("appLanguage") private var appLanguage: AppLanguage = .auto

    var body: some View {
        ClipboardMainView()
            .environmentObject(preferencesStore)
            .environment(runtimeStore)
            .modelContainer(runtimeStore.container)
            .id("\(runtimeStore.rootIdentity)-\(appLanguage.rawValue)")
            .environment(\.locale, appLanguage.resolvedLocale)
    }
}

// MARK: - Notification name

extension Notification.Name {
    static let clipboardLayoutModeChanged = Notification.Name("clipboardLayoutModeChanged")
    static let clipboardPreviewPanelChanged = Notification.Name("clipboardPreviewPanelChanged")
}
