# 横向卡片列表大规模渲染性能优化 — 设计规格

**日期：** 2026-07-27  
**范围：** macOS 面板右侧横向卡片列表（`ScrollView` + `LazyHStack`）及共享数据加载路径  
**约束：** 仅 macOS；不破坏点击 / 右键菜单 / 拖拽；不改数据库 schema；改动收敛在数据加载层与列表/卡片视图  

---

## 1. 背景与目标

### 1.1 背景

Clipaste 面板横向列表按时间倒序展示剪贴板历史。历史可达数百～上千条。当前痛点：

- 首次进入 / 切换分组：界面卡顿数秒后卡片才陆续出现
- 滚动：帧率骤降、不跟手、短暂冻结
- 长时间使用内存持续攀升，未能稳定在合理水位

代码库已具备部分优化（`fetchItemsPage`、`detachedRead`、`ListRenderEngine`、`ClipboardImagePipeline`、warm cache、滚动中禁用动画等），但 **`loadData` 仍会在首屏后自动 while 扫完全库**，且卡片观察面 / ForEach 身份成本仍然偏高。

### 1.2 成功标准（验收）

| 指标 | 标准 |
|------|------|
| 500+ 条库，冷开面板首屏 | **< 500ms** 内完成首批卡片可见渲染，主线程不冻结 |
| 持续横滑 | 稳定 **≥ 55fps**（目标 60） |
| 内存（打开态、约 500 条历史场景） | **< 200MB**，不随库总量线性涨到全量常驻 |
| 滑到当前已加载末尾 | 下一页 **< 300ms** 完成加载并渲染 |
| 交互 | 点击、右键菜单、拖拽行为与现网一致 |
| 切分组 | 不先空白再闪；不触发全库扫 |

### 1.3 非目标

- 不改 SwiftData / 表结构
- 不重写粘贴引擎、剪贴板监控、设置页
- 不强制引入第三方列表库
- 不在本规格中做垂直列表的独立大重构（共享数据层改动会惠及垂直列表；视图层以横向为主，垂直列表做最小对齐）

---

## 2. 现状结论（基于源码）

### 2.1 已具备

| 能力 | 位置 |
|------|------|
| 分页读库 API | `StorageManager.fetchItemsPage` + `ClipboardSearcher` 的 `fetchLimit` / `fetchOffset` |
| 读路径离主线程 | `StorageManager.detachedRead` → `Task.detached(priority: .userInitiated)` |
| 首屏 + 后台流式加载 | `ClipboardViewModel.loadData`：首屏 80，后台页 160 |
| ID 驱动 ForEach | `ClipboardHorizontalView` 用 `displayedItemIDs` + `item(for:)` |
| RTF 异步排版缓存 | `ListRenderEngine`（上限 256，FIFO） |
| 缩略图后台解码 + NSCache | `ClipboardImagePipeline`（count 256 / cost 64MB） |
| 滚动态降载 | `ScrollActivityObserver`、`disableAnimationsWhenScrolling`、quickPaste Preference 在 fling 时关闭 |
| 关面板内存收缩 | `releaseTransientResourcesAfterPanelClose` + warm cache / scope snapshot |

### 2.2 关键缺口

1. **伪分页：** 首屏后 `while` 自动灌满 `items`，打开态内存与 diff 仍随全库增长。  
2. **ForEach 成本：** `Array(displayedItemIDs.enumerated())` 每次 body 全量物化临时数组。  
3. **卡片订阅面过大：** `ClipboardCardView` 持有 `@ObservedObject ClipboardViewModel`，任意 `@Published` 可牵动可见卡。  
4. **分组/筛选依赖内存全量：** 无搜索词时主线程对 `items` O(n) filter；分组正确性依赖 bulk 完成。  
5. **媒体并发无全局上限：** 按 key 去重 ≠ 限制同时 decode / 读库数量。  
6. **部分变更路径 fullRefresh：** `.clipboardDataDidChange` 在面板打开时仍可能 `loadData(.fullRefresh)`。

---

## 3. 根因排序

1. 数据层伪分页 → 全量 `items` 常驻与持续 merge 发布  
2. ForEach 身份列表与 `GeometryReader` 包裹整表的 body 成本  
3. 卡片过重 + 整 VM 观察  
4. 分组/筛选在全量数组上执行  
5. 滚动时 RTF/图片任务并发过猛  
6. 数据变更触发偏重的全量重载  
7. 主线程 DB（已基本治理，优先级最低）

---

## 4. 架构方案

### 4.1 总览

```
┌─────────────────────────────────────────────────────────┐
│  ClipboardHorizontalView                                │
│  ForEach(displayedItemIDs) → Card(Equatable props)      │
│  onAppear(id) → viewModel.loadMoreIfNeeded(id)          │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  ClipboardViewModel                                     │
│  HistoryPaginationState                                 │
│  loadData → 仅首屏 page                                 │
│  loadMoreIfNeeded → 尾部预取下一 page                     │
│  items = 当前已加载窗口（有界），非全库强制常驻              │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  StorageManager.fetchItemsPage (detachedRead)           │
│  可选：group/type predicate + LIMIT/OFFSET               │
└─────────────────────────────────────────────────────────┘
                           │
        ┌──────────────────┼──────────────────┐
        ▼                  ▼                  ▼
 ListRenderEngine   ClipboardImagePipeline   Warm cache
 (RTF, cap 256)     (decode gate ≤4, 64MB)   (首屏即时)
```

### 4.2 数据层：真·按需分页

**状态机：**

```swift
struct HistoryPaginationState: Equatable {
    var loadedCount: Int = 0
    var pageSize: Int = 64          // 首屏/续页统一；可从 80 下调
    var hasMore: Bool = true
    var isLoading: Bool = false
    var generation: UInt = 0        // 取消/覆盖与 dataLoadGeneration 对齐或合并
}
```

**规则：**

1. `loadData(mode:)`：只拉第一页（`offset: 0, limit: pageSize`），应用后结束；**删除 while 全库循环**。  
2. `loadMoreIfNeeded(currentItemID:)`：当 `currentItemID` 落在 `displayedItemIDs` 末尾 **8** 条内，且 `hasMore && !isLoading`，拉下一页并 `appendHistoryPage`。  
3. 搜索 / 分组 / 类型过滤：同一 `generation` 下使用**对应 query 的 offset**；切换 scope 时 `generation &+= 1` 并取消 in-flight。  
4. 关面板裁剪逻辑保留；打开态不再主动把库扫满。  
5. **内存 soft cap（P2，可选增强）：** 打开态已加载条数可设 soft cap（如 400）；超出时优先保留选中、pin、当前可视窗口附近页。首版可不做淘汰，只做「不主动加载超过需要」即可满足主目标。

**线程约定：**

| 步骤 | 线程 |
|------|------|
| UI 触发 `loadMoreIfNeeded` / `loadData` | MainActor |
| `fetchItemsPage` | `detachedRead` → 后台 ModelActor |
| `applyInitialHistoryPage` / `appendHistoryPage` | MainActor |

### 4.3 分组 / 类型过滤（P1）

- **目标：** 切分组不依赖「全量 items 已在内存」。  
- **做法：** 在不改 schema 前提下，为 `ClipboardSearcher` / `StorageManager` 增加带 predicate 的 page API（`groupId` / `typeRawValue` / built-in 条件），ViewModel 在对应 scope 下用 DB page 填充，而不是 `items.compactMap`。  
- **首版可分两阶段：**  
  - P0：全部分组仍可基于已加载窗口（行为可能「加载中结果偏少」——与今日 bulk 中期类似，但不再卡主线程扫全库）。  
  - P1：scope 切换走 DB page，保证分组完整且可续页。

### 4.4 列表渲染

**横向列表（主）：**

- `ForEach(viewModel.displayedItemIDs, id: \.self)`，去掉 `Array(...enumerated())`。  
- quickPaste 序号继续由 Preference + `ClipboardQuickPasteVisibleIndexResolver` 提供，不依赖 ForEach index。  
- 末尾可见卡 `onAppear` → `loadMoreIfNeeded`。  
- 尽量缩小 `GeometryReader` 影响面：若仅 quickPaste 需要 viewport，保持现有但确保 fling 时不 `onPreferenceChange` 写状态（已有 guard）。

**卡片：**

- 输入改为显式 props：`item`、`isSelected`、`searchHighlight`、`quickPasteIndex`、`isScrolling` + 轻量 `actions`（或保留 modifier 所需最小引用）。  
- 实现 `Equatable`，调用处 `.equatable()`。  
- 拆分为 `ClipboardCardHeader` / `ClipboardCardContent` / chrome；交互 modifier（菜单、拖拽、点击）挂在卡片根上，**语义不变**。  
- 滚动中：不 kick off 新的 RTF `prepareText`、不展示 AI 菜单动画（已有部分逻辑，统一到 `isScrolling` / `shouldDisableAnimations`）。

### 4.5 媒体管线

- 保留 `ClipboardImagePipeline` / `ListRenderEngine`。  
- 增加**全局 decode 并发上限**（建议 4）。  
- `isListScrolling == true` 时：新 `.task` 可 sleep/取消，避免 fling 打满读库。  
- 禁止在卡片 body 同步从位图提主色；只用 `appIconDominantColorHex` / 缓存色。

### 4.6 变更通知

- 面板打开时：优先增量（现有 `RecordRefresh` / upsert 路径）。  
- 仅在清库、迁移、明显不一致时 `fullRefresh`（且 fullRefresh = 首屏 page，不再 while 全库）。  
- `.clipboardDataDidChange`：改为 `visibleFirst` 或增量，避免无脑 full 扫库。

---

## 5. 文件与边界

### 5.1 预期修改

| 文件 | 职责 |
|------|------|
| `clipaste/ViewModels/ClipboardViewModel.swift` | `HistoryPaginationState`、pageSize 常量调整 |
| `clipaste/ViewModels/ClipboardViewModel+Filtering.swift` | `loadData` 去 while；`loadMoreIfNeeded` |
| `clipaste/ViewModels/ClipboardViewModel+Presentation.swift` | 首屏/重开与 pagination 对齐；变更订阅模式 |
| `clipaste/ViewModels/ClipboardViewModel+Items.swift` | 如需，append 与 loadedCount 一致性 |
| `clipaste/Views/ClipboardHorizontalView.swift` | ForEach、onAppear loadMore、传参 |
| `clipaste/Views/ClipboardCardView.swift`（及拆分出的子视图文件） | 轻量化、Equatable、缩小观察面 |
| `clipaste/Managers/ClipboardImagePipeline.swift` | 并发门闸 |
| `clipaste/Views/ListRenderEngine.swift` | 可选：滚动友好的取消/限流（若卡片侧不足） |
| `clipaste/Managers/StorageManager.swift` / Searcher | P1：分组/类型 page API |

### 5.2 垂直列表

- 数据层改动自动共享。  
- `ClipboardVerticalListView`：同样去掉不必要的全量 enumerated（若存在）、接 `loadMoreIfNeeded`，保证两布局行为一致。  
- 不做垂直行 UI 重设计。

### 5.3 测试

- 优先对 ViewModel 分页状态做单元测试（generation 取消、尾部触发、scope 切换重置）。  
- UI 用 Instruments 手工验收（见第 7 节）。  
- 若无现成 VM 测试 target，实现计划中写明最小可测方式（纯逻辑 struct 测试或现有 test target）。

---

## 6. 风险与缓解

| 风险 | 缓解 |
|------|------|
| 搜索结果翻页 offset 与过滤不一致 | 搜索续页必须带同一 `searchText`；scope 切换 bump generation |
| 删除/pin 后 `loadedCount` 失真 | 删除时修正 count 或改为 cursor/timestamp 分页（首版修正 count；避免改 schema） |
| 分组在 P0 仅内存窗口 | 文档化；P1 上 DB predicate page |
| Equatable 漏字段导致 UI 不刷新 | 对比 `contentHash`、title、pin、选中、高亮等；手动测编辑/OCR 回填 |
| `drawingGroup` 误用 | **本规格不默认启用**；仅在 Instruments 证明收益后再议 |
| 拖拽/菜单回归 | 交互仍用现有 modifier；评审 checklist 必测 |

---

## 7. 验证

1. **Time Profiler：** 开面板 / 切全部 — 主线程无长时间 `mergeItems` 全库、卡片 body 风暴。  
2. **Core Animation：** 横滑 offscreen/blending 可控。  
3. **SwiftUI Trace：** 滚动时仅可见窗口附近 body 更新。  
4. **Allocations / Memory Graph：** 打开态不随全库线性涨；缓存有界。  
5. **手工：** 500+ 数据下对照第 1.2 节表格；点击/菜单/拖拽/搜索/分组各一遍。

---

## 8. 实施分期

| 阶段 | 内容 | 对应验收 |
|------|------|----------|
| **P0** | 去掉自动 while 全量；`loadMoreIfNeeded`；Horizontal ForEach 简化；卡片观察面 + Equatable 起步 | 首屏 <500ms、滚动帧率、内存主因 |
| **P1** | 垂直列表对齐 loadMore；分组/类型 DB page；图片并发门闸；变更通知减负 | 切分组、长滑稳定 |
| **P2** | 打开态 soft cap / 窗口淘汰（若仍超 200MB）；Geometry 进一步收窄；可选 Trace 微调 | 长时内存 |

---

## 9. 规格自检记录

- [x] 无 TODO/待定占位作为未决需求  
- [x] 验收数字与约束前后一致  
- [x] 不改 schema、保留交互、仅 macOS  
- [x] P0/P1/P2 边界清晰，可单计划覆盖 P0+P1，P2 可选  
- [x] 与现有 `detachedRead` / pipeline / warm cache 兼容，不推倒重来  

---

## 10. 批准

实现计划见：`docs/superpowers/plans/2026-07-27-horizontal-list-perf.md`（随后编写）。

**请审查本规格。** 若需修改请直接指出；批准后按实现计划执行（子代理驱动或内联）。
