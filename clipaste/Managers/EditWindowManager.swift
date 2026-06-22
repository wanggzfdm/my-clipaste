import SwiftUI
import AppKit

/// 编辑窗口定位工具
private enum WindowPositionHelper {
    static let gapAbovePanel: CGFloat = 12
    static let screenMargin: CGFloat = 12
    
    /// 将编辑窗口贴近横向面板上方，而不是放在上方剩余空间的中心。
    /// 这样窗口和触发它的横向剪贴板面板保持视觉关联，更符合从底部面板向上打开详情/编辑的习惯。
    static func frameOver(panelFrame: CGRect, windowSize: NSSize, screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        
        let preferredX = panelFrame.midX - windowSize.width / 2
        let clampedX = max(vf.minX + screenMargin,
                           min(preferredX, vf.maxX - windowSize.width - screenMargin))
        
        let preferredY = panelFrame.maxY + gapAbovePanel
        let clampedY = max(vf.minY + screenMargin,
                           min(preferredY, vf.maxY - windowSize.height - screenMargin))
        
        return NSRect(x: clampedX, y: clampedY, width: windowSize.width, height: windowSize.height)
    }
    
    static func bestScreen(for frame: CGRect?) -> NSScreen? {
        guard let frame else { return NSScreen.main ?? NSScreen.screens.first }
        return NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(frame).width * lhs.frame.intersection(frame).height <
            rhs.frame.intersection(frame).width * rhs.frame.intersection(frame).height
        } ?? NSScreen.main ?? NSScreen.screens.first
    }
    
    static func centeredFrame(windowSize: NSSize, screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        return NSRect(
            x: vf.origin.x + (vf.width - windowSize.width) / 2,
            y: vf.origin.y + (vf.height - windowSize.height) / 2,
            width: windowSize.width,
            height: windowSize.height
        )
    }
}

// ⚠️ 极其核心：自定义窗口子类，打破代码创建窗口的焦点限制
class StandaloneEditWindow: NSWindow {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

    /// ⚠️ 极其核心：Esc 键通过 AppKit 响应链触发窗口关闭，
    /// 自动经由 delegate 的 windowShouldClose 弹出保存确认对话框。
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
    
    /// ⚠️ 极其核心：直接拦截 ESC 键事件，确保在任何情况下都能触发关闭
    override func keyDown(with event: NSEvent) {
        // ESC 键的 keyCode 是 53
        if event.keyCode == 53 {
            performClose(self)
            return
        }
        super.keyDown(with: event)
    }
}

class EditWindowManager: NSObject, NSWindowDelegate {
    static let shared = EditWindowManager()

    // 记录正在编辑的窗口，防止重复打开 [ItemID: NSWindow]
    internal var openWindows: [String: NSWindow] = [:]
    private var lightweightWindows: [String: NSWindow] = [:]

    @MainActor
    func existingLightweightWindow(for item: ClipboardItem) -> NSWindow? {
        lightweightWindows[item.id.uuidString]
    }
    
    @MainActor
    func retainLightweightWindow(_ window: NSWindow, for item: ClipboardItem) {
        let windowId = item.id.uuidString
        lightweightWindows[windowId] = window
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.lightweightWindows.removeValue(forKey: windowId)
            }
        }
    }
    
    @MainActor
    func openEditor(for item: ClipboardItem, viewModel: ClipboardViewModel) {
        let windowId = item.id.uuidString

        // 如果已经打开了，直接拉到最前
        if let existingWindow = openWindows[windowId] {
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        // ⚠️ 在创建/显示编辑窗口之前，预先捕获面板 frame，
        //   因为之后 makeKeyAndOrderFront + activate 可能导致面板自动隐藏。
        let pendingPanelFrame = Self.captureHorizontalPanelFrame()
        
        // 预计算目标 frame（在 makeKeyAndOrderFront 之前设置，避免 AppKit 覆盖位置）
        let windowSize = NSSize(width: 700, height: 500)
        let targetFrame = Self.targetFrame(windowSize: windowSize, overPanelFrame: pendingPanelFrame)

        // 创建独立运行的 SwiftUI 视图
        let editView = StandaloneEditView(item: item, viewModel: viewModel, windowId: windowId)
        let hostingController = NSHostingController(rootView: editView)

        // 创建具有顶级响应者权限的原生窗口
        let window = StandaloneEditWindow(
            contentRect: targetFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = localized("Edit Text")
        window.contentViewController = hostingController
        
        window.isReleasedWhenClosed = false
        window.delegate = self

        // 记录并显示
        openWindows[windowId] = window
        window.setFrame(targetFrame, display: false)
        
        // ⚠️ 重要：先设置 frame 再显示窗口，避免 AppKit 自动居中覆盖位置
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        NSApp.activate(ignoringOtherApps: true)

        // 暂停盲打搜索拦截，防止编辑窗口中的键盘输入被主面板劫持
        TypeToSearchService.shared.isPaused = true
    }
    
    /// 捕获当前横向面板的 frame（用于编辑窗口定位）
    /// 必须在 makeKeyAndOrderFront / activate 之前调用。
    static func captureHorizontalPanelFrame() -> CGRect? {
        let panelManager = ClipboardPanelManager.shared
        guard panelManager.isVisible,
              let panel = panelManager.panel,
              AppLayoutMode(
                  rawValue: UserDefaults.standard.string(forKey: "clipboardLayout")
                      ?? AppLayoutMode.horizontal.rawValue
              ) == .horizontal
        else { return nil }
        return panel.frame
    }
    
    /// 编辑窗口定位：横向面板正上方 / 回退到可见区域居中。
    static func targetFrame(windowSize: NSSize, overPanelFrame panelFrame: CGRect?) -> NSRect {
        guard let screen = WindowPositionHelper.bestScreen(for: panelFrame) else {
            return NSRect(origin: .zero, size: windowSize)
        }
        
        if let panelFrame {
            return WindowPositionHelper.frameOver(panelFrame: panelFrame, windowSize: windowSize, screen: screen)
        }
        
        return WindowPositionHelper.centeredFrame(windowSize: windowSize, screen: screen)
    }
    
    /// 编辑窗口定位：横向面板正上方 / 回退到可见区域居中。
    static func positionWindowOnScreen(_ window: NSWindow, overPanelFrame panelFrame: CGRect?) {
        window.setFrame(targetFrame(windowSize: window.frame.size, overPanelFrame: panelFrame), display: true)
    }

    // ⚠️ 极其核心：拦截窗口关闭事件，对标 PasteNow 的未保存提示
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 查找对应的 Item ID
        guard let windowId = openWindows.first(where: { $1 === sender })?.key else { return true }

        let alert = NSAlert()
        alert.messageText = localized("Save Changes?")
        alert.informativeText = localized("Unsaved Edit Changes Message")
        alert.addButton(withTitle: localized("Save"))
        alert.addButton(withTitle: localized("Don't Save"))
        alert.addButton(withTitle: localized("Cancel"))

        // 使用原生的 Sheet 形式附着在当前窗口上
        alert.beginSheetModal(for: sender) { response in
            switch response {
            case .alertFirstButtonReturn: // 保存
                // 发送保存通知，让 SwiftUI 视图执行保存逻辑
                NotificationCenter.default.post(name: NSNotification.Name("SaveEdit-\(windowId)"), object: nil)
                self.closeAndCleanUp(windowId: windowId, window: sender)
            case .alertSecondButtonReturn: // 不保存
                self.closeAndCleanUp(windowId: windowId, window: sender)
            default: // 取消
                break
            }
        }
        return false // 拦截默认的直接关闭行为
    }

    @MainActor
    private func closeAndCleanUp(windowId: String, window: NSWindow) {
        window.delegate = nil
        window.close()
        openWindows.removeValue(forKey: windowId)

        // 所有编辑窗口关闭后恢复盲打搜索拦截
        if openWindows.isEmpty {
            TypeToSearchService.shared.isPaused = false
        }
    }

    // 供 SwiftUI 内部点击"保存"按钮时主动调用的关闭方法
    @MainActor
    func forceClose(windowId: String) {
        if let window = openWindows[windowId] {
            closeAndCleanUp(windowId: windowId, window: window)
        }
    }

    private func localized(_ key: String) -> String {
        let language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .auto
        let resource = LocalizedStringResource(String.LocalizationValue(key), locale: language.resolvedLocale, bundle: .main)
        return String(localized: resource)
    }
}
