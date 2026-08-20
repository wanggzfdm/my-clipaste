import SwiftUI
import AppKit

// MARK: - Modern Glass Effect

/// 现代化玻璃效果组件 - 支持 macOS 14+ 的超透明材质
struct ModernGlassEffect: View {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var cornerRadius: CGFloat = 16
    var borderWidth: CGFloat = 0.5
    var borderColor: Color = .white.opacity(0.2)
    
    var body: some View {
        ZStack {
            // 玻璃模糊层
            VisualEffectView(material: material, blendingMode: blendingMode)
                .ignoresSafeArea()
            
            // 半透明背景
            Color.black.opacity(0.05)
                .ignoresSafeArea()
            
            // 边框
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(borderColor, lineWidth: borderWidth)
                .ignoresSafeArea()
            
            // 高光效果
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.3),
                            Color.white.opacity(0.05),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .ignoresSafeArea()
        }
    }
}

// MARK: - Glass Panel

/// 玻璃面板 - 用于卡片和面板
struct GlassPanel<Content: View>: View {
    let content: Content
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var cornerRadius: CGFloat = 12
    var padding: CGFloat = 0
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        ZStack {
            VisualEffectView(material: material, blendingMode: blendingMode)
                .cornerRadius(cornerRadius)
            
            Color.black.opacity(0.03)
                .cornerRadius(cornerRadius)
            
            content
                .padding(padding)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
    }
}

// MARK: - Ultra Thin Glass

/// 超透明玻璃 - 用于背景
struct UltraThinGlass: View {
    var cornerRadius: CGFloat = 0
    var opacity: Double = 0.7
    
    var body: some View {
        ZStack {
            Color(NSColor.controlBackgroundColor)
                .opacity(0.3)
            
            VisualEffectView(material: .underWindowBackground, blendingMode: .withinWindow)
                .opacity(opacity)
        }
        .background(Color.white.opacity(0.05))
    }
}

// MARK: - Enhanced Glass Card

/// 增强玻璃卡片 - 用于列表项
struct GlassCard<Content: View>: View {
    let content: Content
    var isSelected: Bool = false
    var isHovered: Bool = false
    var cornerRadius: CGFloat = 8
    
    init(isSelected: Bool = false, isHovered: Bool = false, @ViewBuilder content: () -> Content) {
        self.isSelected = isSelected
        self.isHovered = isHovered
        self.content = content()
    }
    
    var body: some View {
        ZStack {
            // 背景
            if isSelected {
                Color.accentColor.opacity(0.15)
            } else if isHovered {
                Color(NSColor.controlBackgroundColor).opacity(0.6)
            } else {
                Color.clear
            }
            
            // 玻璃效果
            VisualEffectView(material: .menu, blendingMode: .behindWindow)
                .opacity(isSelected || isHovered ? 0.5 : 0.3)
            
            content
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.1),
                    lineWidth: isSelected ? 1.5 : 0.5
                )
        )
    }
}

// MARK: - Sidebar Glass

/// 侧边栏玻璃效果
struct SidebarGlass: View {
    var body: some View {
        ZStack {
            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                .ignoresSafeArea()
            
            Color.black.opacity(0.02)
                .ignoresSafeArea()
        }
    }
}

// MARK: - Window Background Glass

/// 窗口背景玻璃效果
struct WindowBackgroundGlass: View {
    var body: some View {
        ZStack {
            VisualEffectView(material: .popover, blendingMode: .behindWindow)
                .ignoresSafeArea()
            
            // 微妙的渐变
            LinearGradient(
                colors: [
                    Color.white.opacity(0.08),
                    Color.clear,
                    Color.black.opacity(0.03)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }
}

// MARK: - Paste Panel Glass (fork 2.1.5)

/// Paste 风格主面板毛玻璃：更透的 behind-window blur + 轻量暗色罩层 + 顶部高光。
/// 竖/横统一用 hudWindow，避免 popover 材质过实。
struct PastePanelBackgroundGlass: View {
    var isHorizontal: Bool = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // Base blur — fork horizontal path; also used for vertical paste for clearer glass.
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            // Soft dark wash — lighter than a solid fill so desktop shows through.
            LinearGradient(
                colors: darkWashColors,
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // Top specular highlight (glass edge)
            LinearGradient(
                colors: [
                    Color.white.opacity(isHorizontal
                        ? (colorScheme == .dark ? 0.06 : 0.28)
                        : (colorScheme == .dark ? 0.05 : 0.18)),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: UnitPoint(x: 0.5, y: isHorizontal ? 0.45 : 0.35)
            )
            .ignoresSafeArea()

            // Subtle bottom depth without killing translucency
            LinearGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(colorScheme == .dark ? 0.08 : 0.04)
                ],
                startPoint: UnitPoint(x: 0.5, y: 0.55),
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private var darkWashColors: [Color] {
        if colorScheme == .dark {
            // fork used ~0.26/0.14 black; slightly lighter so blur reads more clearly.
            return [
                Color.black.opacity(isHorizontal ? 0.18 : 0.14),
                Color.black.opacity(isHorizontal ? 0.10 : 0.08)
            ]
        }
        return [
            Color(nsColor: .windowBackgroundColor).opacity(0.20),
            Color(nsColor: .windowBackgroundColor).opacity(0.10)
        ]
    }
}

// MARK: - Preview

#Preview("Modern Glass Effect") {
    ModernGlassEffect(material: .hudWindow)
        .frame(width: 400, height: 300)
}

#Preview("Glass Panel") {
    GlassPanel {
        Text("Glass Panel Content")
            .font(.headline)
            .padding()
    }
    .frame(width: 300, height: 200)
}

#Preview("Glass Card") {
    GlassCard(isSelected: true, isHovered: false) {
        Text("Selected Card")
            .padding()
    }
    .frame(width: 200, height: 100)
}
