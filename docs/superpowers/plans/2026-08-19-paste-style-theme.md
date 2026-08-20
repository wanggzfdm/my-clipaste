# Paste 风格主题实现计划

> **面向 AI 代理的工作者：** 按任务顺序实现；每任务可编译验证。

**目标：** 在 `user/v2.2.10` 增加 `AppTheme.paste`，主面板外观/动效对齐 fork 2.1.5。

**架构：** `AppTheme.paste` → 固定 dark；`PanelVisualStyle` token 驱动 Main/Card/List/Header；迁入 GlassEffects + SearchResultsTransition；standard 保持现状。

**技术栈：** SwiftUI / AppKit VisualEffect / @AppStorage

**规格：** `docs/superpowers/specs/2026-08-19-paste-style-theme-design.md`

---

### 任务 1：主题模型 + 策略测试
- 修改 `AppTheme.swift`：加 `paste`，colorScheme/darkAqua/displayName
- 新建 `PanelVisualStyle.swift` + `PastePanelChrome` 基础 token
- 脚本测试映射

### 任务 2：设置预览
- `GeneralSettingsView` AppearanceThemePreview 支持 paste 深色玻璃示意
- 本地化「Paste 风格」

### 任务 3：迁入 fork 组件
- `GlassEffects.swift`、`SearchResultsTransitionContainer.swift`（当前缺失）

### 任务 4：主面板接入
- Main / Card / Vertical* / Horizontal / Header / Empty 按 style 切换 chrome
- Logo 暗色 AppIcon

### 任务 5：编译与安装验证
- Debug build + 策略测试
---

实现时以 fork `user/fork-work-v2.1.5` 对应文件数值为准。
