# Clipaste 页面加载动画实现说明

> 本文档说明 Clipaste 历史面板「加载中 → 列表出现」的动画实现，参考 Paste.app 的动画机制（Ghidra 反编译实证），并给出调整指南。

---

## 1. 背景：Paste 的动画机制（实证）

通过 rea + Ghidra 反编译 Paste 主程序（`/tmp/paste_arm64`）的 SwiftUI/AppKit 符号，确认 Paste 的页面/加载动画使用的机制：

| 类别 | 符号（实证） | 用途 |
|---|---|---|
| SwiftUI 动画 | `SwiftUI::Animation::spring` / `interactiveSpring` / `.easeOut` / `.easeInOut` | 弹性/缓动动画 |
| 视图过渡 | `AnyTransition::asymmetric(insertion:removal:)` + `.move` + `OpacityTransition` / `PushTransition` | 视图进出场 |
| 窗口过渡 | `PasteRouting.WindowTransition`（`windowWillClose:`） | 面板开/关 |
| 列表行动画 | `NSTableView insertRowsAtIndexes:withAnimation:` / `removeRowsAtIndexes:` + `NSAnimationContext.runAnimationGroup:` | 列表行增删 |
| Core Animation | `CABasicAnimation` / `CAKeyframeAnimation` | 高级关键帧动画 |

**核心结论**：Paste 用「**spring 弹性动画 + asymmetric(move/opacity) 过渡**」呈现面板与历史列表，追求轻快、有「浮现感」而非生硬切换。

---

## 2. Clipaste 改动前现状

- 加载状态由 `ClipboardViewModel.isInitialHistoryLoading` 标记（`clipaste/ViewModels/ClipboardViewModel.swift:76`）。
- 骨架屏已存在（`ClipboardEmptyStateView.swift` 的 `loadingPlaceholder`），但为**静态**占位、无扫光。
- 主切换点在 `ClipboardMainView+InputLifecycle.swift` 的 `mainContent`：
  - `displayedItems.isEmpty` → `ClipboardEmptyStateView`（骨架屏/空态）
  - 否则 → `ClipboardHorizontalView` / `ClipboardVerticalListView`
- **问题**：骨架屏 → 列表为**瞬间硬切换**，无过渡动画，加载中无「正在读取」的视觉反馈。

---

## 3. 本次实现的两处动画

### 3.1 骨架屏 → 列表的 spring 过渡（`ClipboardMainView+InputLifecycle.swift`）

```swift
@ViewBuilder
var mainContent: some View {
    Group {
        if displayedItems.isEmpty {
            ClipboardEmptyStateView(viewModel: viewModel)
                .transition(.opacity)
        } else {
            switch clipboardLayout {
            case .horizontal:
                ClipboardHorizontalView(...).transition(listRevealTransition)
            case .vertical, .compact:
                ClipboardVerticalListView(...).transition(listRevealTransition)
            }
        }
    }
    .animation(.spring(response: 0.28, dampingFraction: 0.85), value: displayedItems.isEmpty)
}

/// 历史列表从骨架屏浮现时的过渡：淡入 + 轻微放大 + 自底部上移；离开时仅淡出。
private var listRevealTransition: AnyTransition {
    .asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.985)).combined(with: .move(edge: .bottom)),
        removal: .opacity
    )
}
```

**设计要点**：
- **value 用 `displayedItems.isEmpty`**：只在「空 ↔ 非空」切换时触发动画；分页加载向列表追加 item 时该 Bool 不变，**不会**触发重动画，避免高频闪烁。
- **insertion**：`opacity`（淡入）+ `scale(0.985)`（轻微放大到原尺寸）+ `move(.bottom)`（自底部上移）——对齐 Paste 的「浮现感」。
- **removal**：仅 `opacity` 淡出，离开列表时（如搜索无结果切回空态）保持克制。
- **spring(0.28, 0.85)**：响应 0.28s、阻尼 0.85，轻快带回弹，不过度。

### 3.2 骨架屏 shimmer 扫光（`ClipboardEmptyStateView.swift`）

```swift
@State private var shimmerOffset: CGFloat = -600

private var loadingPlaceholder: some View {
    skeletonStack
        .overlay { shimmerOverlay }
        .clipped()
}

private var shimmerOverlay: some View {
    GeometryReader { geo in
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: Color.white.opacity(0.14), location: 0.5),
                .init(color: .clear, location: 1)
            ],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(width: geo.size.width * 0.6)
        .offset(x: shimmerOffset)
        .onAppear {
            shimmerOffset = -geo.size.width * 0.7
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                shimmerOffset = geo.size.width * 1.3
            }
        }
    }
    .allowsHitTesting(false)
    .blendMode(.plusLighter)
}
```

**设计要点**：
- 将原 `loadingPlaceholder` 拆为 `skeletonStack`（静态骨架）+ `shimmerOverlay`（扫光层），职责分离。
- 扫光用 `LinearGradient`（clear→白0.14→clear）＋横向 `offset` 位移，`repeatForever(autoreverses: false)` 循环自左向右。
- `blendMode(.plusLighter)` 让高光叠加在骨架之上，不覆盖底色。
- `allowsHitTesting(false)` 避免遮挡点击。

---

## 4. 验证

- 已在 Xcode Debug 构建通过（`xcodebuild -scheme Clipaste -configuration Debug` → **BUILD SUCCEEDED**）。
- 本次改动无关的既有 warning：`ClipboardPasteCardView.swift:510/623`（ViewBuilder / MainActor），不涉及本次动画。

---

## 5. 调整指南

| 想调整 | 改哪里 |
|---|---|
| 过渡速度/回弹 | `ClipboardMainView+InputLifecycle.swift` 的 `spring(response:dampingFraction:)`（response 越小越快，dampingFraction 越小越弹） |
| 列表进入方向 | `listRevealTransition` 的 `.move(edge:)`（`.bottom`/`.top`/`.leading`/`.trailing`）或移除 `.scale` |
| 离开动画 | `listRevealTransition` 的 `removal`（当前仅 opacity） |
| 扫光速度 | `ClipboardEmptyStateView.swift` `shimmerOverlay` 的 `linear(duration:)` |
| 扫光强度 | 渐变 stops 中 `Color.white.opacity(0.14)` 的透明度 |
| 关闭动画 | 移除 `mainContent` 上的 `.animation(...)` 与各分支 `.transition(...)` |

> 若需列表项「逐个浮现」（staggered entrance），可在 `ClipboardVerticalListView` 的 `LazyVStack` 内对每个 item 按 index 施加延迟位移/透明度过渡（参考 Paste 的行插入动画），但需注意 Lazy 容器对不可见项不实例化，延迟过渡需配合 `onAppear` 触发。

---

## 6. 涉及文件

- `clipaste/Views/ClipboardMainView+InputLifecycle.swift` — `mainContent` 过渡 + `listRevealTransition`
- `clipaste/Views/ClipboardEmptyStateView.swift` — `skeletonStack` + `shimmerOverlay`