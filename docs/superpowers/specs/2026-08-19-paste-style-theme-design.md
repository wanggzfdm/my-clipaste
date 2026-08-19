# Paste 风格主题设计

日期：2026-08-19  
分支：`user/v2.2.10`  
参考：`user/fork-work-v2.1.5` 主面板外观  
状态：待用户审查规格

## 目标

在当前 2.2.10 分支新增可选外观主题 **「Paste 风格」**。用户在设置 → 外观中切换后，**剪贴板主面板**的配色、材质、圆角/描边/阴影与关键动效对齐 fork 2.1.5；品牌 Logo 使用现有暗色 AppIcon。未选择该主题时，保持现有 2.2.10 行为不变。

## 非目标

- 不改设置页、关于页、AI / 翻译等次要窗口外观
- 不整文件覆盖为 fork 双视图树（避免双倍维护）
- 不在本任务重做分组 SQL / 内存逻辑
- 不新增完整图标资源包（复用现有暗色 AppIcon / MenuBar 资源）
- Paste 主题不提供独立浅色变体（固定暗色）

## 用户决策（已确认）

| 项 | 选择 |
| --- | --- |
| 作用范围 | 仅剪贴板主面板 |
| 接入方式 | `AppTheme` 增加 `paste` case |
| 明暗 | 选中 Paste = 固定 `dark` / `darkAqua` |
| Logo | 使用现有暗色 logo（AppIcon） |

## 架构

### 1. 主题枚举

扩展 `clipaste/Models/AppTheme.swift`：

```text
system | light | dark | paste
```

- `paste.displayName`：`Paste 风格`（本地化键可先英/中并行）
- `paste.colorScheme` → `.dark`
- `paste.nsAppearanceName` → `.darkAqua`
- `WindowAppearanceObserver` 已消费 `AppTheme`，无需新窗口观察器；确认 `paste` 走 darkAqua 即可

`@AppStorage("appTheme")` 仍用 `String` rawValue；旧值 `system/light/dark` 兼容，未知值回退 `system`（若解码失败由默认值处理）。

### 2. 视觉风格解析

新增轻量解析层（建议文件名其一）：

- `clipaste/Models/PanelVisualStyle.swift`，或
- `clipaste/Views/PastePanelChrome.swift`

```text
enum PanelVisualStyle {
  case standard   // 当前 2.2.10
  case paste      // fork 2.1.5 主面板
}

extension AppTheme {
  var panelVisualStyle: PanelVisualStyle {
    self == .paste ? .paste : .standard
  }
}
```

**原则：** 视图不直接 `if appTheme == .paste` 散落魔法数；通过 `PanelVisualStyle` / `PastePanelChrome` 读 token（材质、圆角、描边透明度、选中阴影、动效参数）。`standard` token 等于现状硬编码值，保证默认像素级不变。

### 3. 从 fork 抽取的 token 范围（主面板）

对照 `user/fork-work-v2.1.5` 与当前差异较大的文件：

| 区域 | fork 特征（摘要） | standard（现状摘要） |
| --- | --- | --- |
| 面板背景 | `hudWindow` + 玻璃叠层 / `WindowBackgroundGlass` / `ModernGlassEffect` | `popover` 材质 |
| 面板圆角 | 连续圆角 `panelCornerRadius`（布局相关） | vertical/compact 约 14，否则 0 |
| 卡片 | 连续圆角、选中描边+阴影、浅渐变叠层 | 较平的上游卡片 |
| 列表行 | hover/选中透明度与 fork 一致 | 上游值 |
| 搜索结果过渡 | `SearchResultsTransitionContainer` settle | 无或更弱 |
| 空状态 | fork 微调透明度/间距 | 保持 standard |

实现时以 fork 源文件为权威数值来源，写入 token，不靠目测估数。

### 4. 视图接入点（仅这些）

必须按 style 分支或 modifier 的文件：

1. `ClipboardMainView.swift` — 背景材质、玻璃、外轮廓圆角、布局相关 padding 若 fork 不同则 token 化  
2. `ClipboardCardView.swift` — 卡片 chrome、选中/hover、阴影策略  
3. `ClipboardVerticalItemView.swift` / `ClipboardVerticalListView.swift` / `ClipboardVerticalView.swift` / `ClipboardHorizontalView.swift` — 列表/横滑与 fork 对齐的外观与过渡  
4. `ClipboardHeaderView.swift` — 头部控件材质/对比度；品牌位 Logo（paste 用暗色 AppIcon）  
5. `ClipboardEmptyStateView.swift` — 空状态外观微调  
6. 引入 fork 已有组件（若当前缺失）：  
   - `GlassEffects.swift`（`ModernGlassEffect` / `GlassPanel` / 相关 `VisualEffect` 包装）  
   - `SearchResultsTransitionContainer.swift`  
   paste 时启用；standard 路径不强制改变动画行为  

**禁止**在本任务中改：`SettingsView` 视觉体系、同步/存储逻辑、ViewModel 业务（除非仅为注入 `@AppStorage("appTheme")` 读 style）。

### 5. 设置 UI

`GeneralSettingsView` → `AppearanceThemePicker` / `AppearanceThemeCard` / `AppearanceThemePreview`：

- `ForEach(AppTheme.allCases)` 自动多出 Paste 卡片  
- Preview：深色玻璃示意（小面板 + 圆角卡片剪影），与 Light/Dark/System 区分  
- 文案：`Paste 风格` / 英文 `Paste`

主题色（`AppAccentColor`）在 paste 下仍可用：选中描边/强调色继续读 accent，与 fork 一致（fork 亦用 accent）。

### 6. Logo

- Paste 下主面板品牌/关于入口若展示 App 图标：使用 `AppIcon` 资源（暗色稿）  
- 菜单栏图标是否切换：本规格 **可选**，默认 **不强制改菜单栏**，避免与系统 template 图标冲突；若实现成本低且 fork 有明确差异，可一并切换 MenuBar 资源，但非验收阻塞项  

### 7. 动画

- 操作提示 spring：可与 fork 对齐（若已相同则不动）  
- 搜索结果：paste 启用 `SearchResultsTransitionContainer`  
- 分组/筛选切换：fork 若对部分 `animation(nil, value:)` 做了降噪，paste 跟随；standard 保持现状  
- 遵守 `accessibilityReduceMotion`

## 数据流

```text
用户选择 AppTheme.paste
  → @AppStorage("appTheme") 持久化
  → WindowAppearanceObserver 应用 darkAqua
  → 主面板 .preferredColorScheme(.dark)（已有 theme 管道则复用）
  → 各 View 读 appTheme.panelVisualStyle == .paste
  → 应用 PastePanelChrome tokens + Glass / Search transition
```

## 错误与兼容

- 存储值为未知字符串：回退 `.system`（或保持 `AppTheme` raw 解码失败时的默认）  
- 从 paste 切回 light/system：立即恢复 standard chrome 与对应 appearance，无残留 glass 状态  
- 不迁移其它设置键  

## 测试

本分支无完整 XCTest target 时：

1. 纯逻辑脚本/单测（可放 `scripts/` 或 Models 旁可编译测）：  
   - `AppTheme.paste` → dark colorScheme / darkAqua / `panelVisualStyle == .paste`  
   - 其它 case → `.standard`  
2. Token：`standard` 关键常量与重构前硬编码一致（防回归）  
3. Debug/Release 编译通过  
4. 手动：设置切换 System/Light/Dark/Paste；Paste 下面板为暗色玻璃风；切回 Light 恢复上游浅色  

## 实现顺序建议

1. `AppTheme.paste` + 本地化 + Appearance 预览卡  
2. `PanelVisualStyle` / `PastePanelChrome` token  
3. 迁入 `GlassEffects` + `SearchResultsTransitionContainer`（若缺失）  
4. 按 Main → Card → Vertical/Horizontal → Header → Empty 接入  
5. Logo 暗色资源  
6. 测试脚本 + 编译验证  

## 验收标准

- [ ] 外观可选「Paste 风格」  
- [ ] 选中后面板为暗色，视觉与 fork 2.1.5 主面板明显一致（玻璃、卡片选中、动效）  
- [ ] System/Light/Dark 与改前一致（无回归）  
- [ ] 设置页等非主面板不要求变成 fork 风  
- [ ] 编译通过；主题映射测试通过  

## 风险

| 风险 | 缓解 |
| --- | --- |
| fork 视图与 2.2.10 结构分叉大，整文件 diff 难合 | token + 局部 modifier，禁止整文件替换业务逻辑 |
| Glass 组件与现有 `VisualEffectView` 重复 | 优先复用已有 VisualEffect；GlassEffects 只补 fork 独有 API |
| 动画在列表大数据下掉帧 | 跟随 fork 的 `animation(nil)` 降噪；不引入额外 matchedGeometry 全列表 |
| 本地化字符串 | xcstrings 增加键；中文「Paste 风格」 |

## 参考路径

- 主题：`clipaste/Models/AppTheme.swift`  
- 设置外观：`clipaste/Views/GeneralSettingsView.swift`  
- 主面板：`clipaste/Views/ClipboardMainView.swift` 等  
- fork 参考分支：`user/fork-work-v2.1.5`  
- fork 独有/增强：`GlassEffects.swift`、`SearchResultsTransitionContainer.swift`  
