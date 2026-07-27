# 横向卡片列表性能优化 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 将剪贴板横向卡片列表从「首屏后自动灌满全库」改为真·按需分页，并降低 ForEach/卡片订阅成本，达到首屏 <500ms、滚动 ≥55fps、打开态内存 <200MB（500 条场景）。

**架构：** ViewModel 引入 `HistoryPaginationState`；`loadData` 只拉第一页，`loadMoreIfNeeded` 在列表尾部预取；Horizontal/Vertical ForEach 改为纯 ID 列表并在 `onAppear` 触发续页；卡片收窄观察面并 `Equatable`；ImagePipeline 增加并发门闸。不改 DB schema。

**技术栈：** SwiftUI（macOS）、Swift Concurrency、SwiftData（现有 `StorageManager` / `ClipboardSearcher`）、Combine（现有订阅）

**规格：** `docs/superpowers/specs/2026-07-27-horizontal-list-perf-design.md`

---

## 文件结构（将创建 / 修改）

| 文件 | 动作 | 职责 |
|------|------|------|
| `clipaste/ViewModels/ClipboardViewModel.swift` | 修改 | 分页状态、pageSize 常量 |
| `clipaste/ViewModels/ClipboardViewModel+Filtering.swift` | 修改 | `loadData` 去 while；实现 `loadMoreIfNeeded` |
| `clipaste/ViewModels/ClipboardViewModel+Presentation.swift` | 修改 | 首屏/重开与 pagination；dataDidChange 减负 |
| `clipaste/ViewModels/ClipboardViewModel+Items.swift` | 修改 | 删除时修正 `pagination.loadedCount`（如需要） |
| `clipaste/Views/ClipboardHorizontalView.swift` | 修改 | ForEach + onAppear loadMore + 卡片传参 |
| `clipaste/Views/ClipboardVerticalListView.swift` | 修改 | 对齐 loadMore / ForEach |
| `clipaste/Views/ClipboardCardView.swift` | 修改 | Equatable props；拆分或内联子视图 |
| `clipaste/Views/ClipboardCardHeaderView.swift` | 创建（可选） | 卡片头部 |
| `clipaste/Views/ClipboardCardContentView.swift` | 创建（可选） | 卡片内容区 |
| `clipaste/Managers/ClipboardImagePipeline.swift` | 修改 | 全局 decode 并发上限 |
| `clipaste/Managers/StorageManager.swift` | 修改（P1） | 分组/类型 page API |
| 测试文件（见任务 1） | 创建/修改 | 分页状态机单测 |

---

### 任务 1：分页状态类型与单测骨架

**文件：**
- 修改：`clipaste/ViewModels/ClipboardViewModel.swift`
- 创建或修改：项目内现有 Unit Test target 下的测试文件（若无 VM 测试 target，则在 `clipasteTests` 或等价目录创建 `HistoryPaginationStateTests.swift`；实现前用 `fffind`/`xcodebuild -list` 确认 target 名）

- [ ] **步骤 1：在 ViewModel 中加入分页状态（先不改 load 行为）**

在 `ClipboardViewModel.swift` 的常量区附近加入：

```swift
struct HistoryPaginationState: Equatable {
    var loadedCount: Int = 0
    var pageSize: Int = 64
    var hasMore: Bool = true
    var isLoading: Bool = false
    /// 与 dataLoadGeneration 同步使用：每次 loadData / scope 重置时递增
    var generation: UInt = 0
}
```

在 `ClipboardViewModel` 中增加：

```swift
var pagination = HistoryPaginationState()
```

将现有：

```swift
static let initialVisibleItemBatchSize = 80
static let backgroundPageBatchSize = 160
```

调整为（保持旧名作别名以免大范围编译失败，或全局替换为 `pagination.pageSize` 语义）：

```swift
static let initialVisibleItemBatchSize = 64
static let backgroundPageBatchSize = 64  // 续页与首屏同尺寸；任务 2 删除 bulk while 后此常量仅用于 pageSize
static let historyPageSize = 64
static let loadMorePrefetchDistance = 8
```

- [ ] **步骤 2：编写分页状态相关的纯逻辑测试（若可抽 helper）**

优先测试不依赖 SwiftData 的决策函数。若将「是否应 load more」抽为：

```swift
enum HistoryPaginationPolicy {
    static func shouldLoadMore(
        currentID: UUID,
        displayedIDs: [UUID],
        state: HistoryPaginationState,
        prefetchDistance: Int = ClipboardViewModel.loadMorePrefetchDistance
    ) -> Bool {
        guard state.hasMore, state.isLoading == false else { return false }
        guard let index = displayedIDs.firstIndex(of: currentID) else { return false }
        return index >= displayedIDs.count - prefetchDistance
    }
}
```

测试示例：

```swift
func testShouldLoadMoreWhenNearEnd() {
    let ids = (0..<20).map { _ in UUID() }
    var state = HistoryPaginationState(loadedCount: 20, hasMore: true, isLoading: false)
    XCTAssertTrue(
        HistoryPaginationPolicy.shouldLoadMore(
            currentID: ids[15],
            displayedIDs: ids,
            state: state
        )
    )
    XCTAssertFalse(
        HistoryPaginationPolicy.shouldLoadMore(
            currentID: ids[0],
            displayedIDs: ids,
            state: state
        )
    )
    state.isLoading = true
    XCTAssertFalse(
        HistoryPaginationPolicy.shouldLoadMore(
            currentID: ids[19],
            displayedIDs: ids,
            state: state
        )
    )
}
```

- [ ] **步骤 3：运行测试确认失败或编译通过后失败断言路径清晰**

```bash
xcodebuild test -scheme Clipaste -destination 'platform=macOS' -only-testing:clipasteTests/HistoryPaginationStateTests
```

（scheme/target 名以实现时 `xcodebuild -list` 为准。）

- [ ] **步骤 4：放入 policy helper，使测试通过**

- [ ] **步骤 5：Commit**

```bash
git add clipaste/ViewModels/ClipboardViewModel.swift \
  clipaste/ViewModels/HistoryPaginationPolicy.swift \
  clipasteTests/HistoryPaginationStateTests.swift  # 路径以实际为准
git commit -m "feat(list-perf): add HistoryPaginationState and load-more policy"
```

---

### 任务 2：`loadData` 仅首屏 + 实现 `loadMoreIfNeeded`

**文件：**
- 修改：`clipaste/ViewModels/ClipboardViewModel+Filtering.swift`
- 修改：`clipaste/ViewModels/ClipboardViewModel+Presentation.swift`（`refreshFirstHistoryPageForPresentation` 与 pagination 字段对齐）

- [ ] **步骤 1：重写 `loadData`，删除 while 全量循环**

将 `loadData(mode:)` 改为：

1. `pagination.generation &+= 1`（或继续用 `dataLoadGeneration` 并同步写入 `pagination.generation`）
2. cancel `historyLoadTask`
3. `pagination.isLoading = true`，`hasMore = true`
4. 若 `items`/`displayedItems` 空 → `isInitialHistoryLoading = true`
5. Task 内 `fetchItemsPage(searchText: "", fetchLimit: pageSize, offset: 0)`
6. MainActor：`applyInitialHistoryPage`；设置  
   `pagination.loadedCount = firstPage.count`  
   `pagination.hasMore = firstPage.count == pageSize`  
   `pagination.isLoading = false`  
   `isBulkHistoryLoading = false`（不再进入 bulk 模式）  
   `isLoadingMoreHistory = false`  
   `hasLoadedFullHistory = !pagination.hasMore`

**禁止**再出现 `while !Task.isCancelled { fetch... append... sleep }` 全库循环。

- [ ] **步骤 2：实现 `loadMoreIfNeeded(currentItemID:)`**

```swift
@MainActor
func loadMoreIfNeeded(currentItemID: UUID) {
    guard HistoryPaginationPolicy.shouldLoadMore(
        currentID: currentItemID,
        displayedIDs: displayedItemIDs,
        state: pagination
    ) else { return }

    // 搜索 scope：续页必须带当前 activeSearchQuery（trim 后）
    let query = activeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    // P0：无分组 DB API 前，仅在「全部 + 无类型过滤 + 无内置分组」或已与内存 filter 一致的路径续页。
    // 若存在 group/type/builtIn 且仅内存过滤，续页仍拉全局 page 再 filter 会错位——
    // P0 约定：有 active scope（非全部）时，loadMore 仍 fetch 全局下一页并 merge + refreshDisplayedItemsFromCurrentScope
    // （与旧 bulk 中期行为类似，但不自动扫完）。P1 再换 DB predicate。

    pagination.isLoading = true
    isLoadingMoreHistory = true
    let generation = dataLoadGeneration
    let offset = pagination.loadedCount
    let pageSize = pagination.pageSize

    historyLoadTask = Task(priority: .userInitiated) { [weak self] in
        guard let self else { return }
        let page = await StorageManager.shared.fetchItemsPage(
            searchText: "", // P0 搜索续页：若 query 非空，应传 query（与 Searcher 行为一致）
            fetchLimit: pageSize,
            offset: offset
        )
        guard !Task.isCancelled, generation == self.dataLoadGeneration else { return }
        await MainActor.run {
            self.appendHistoryPage(page, generation: generation, loadedCount: offset + page.count)
            self.pagination.loadedCount = offset + page.count
            self.pagination.hasMore = page.count == pageSize
            self.pagination.isLoading = false
            self.isLoadingMoreHistory = false
            if page.isEmpty || page.count < pageSize {
                self.hasLoadedFullHistory = true
            }
        }
    }
}
```

注意：当 `query` 非空时，`fetchItemsPage(searchText: query, ...)`，且 `offset` 必须是**该 query 结果集**上的 offset。为此在 pagination 中可增加 `activeQueryForPagination: String`，在 `loadData`/搜索变更时重置。

搜索重置逻辑（写进 Filtering）：

```swift
// 在 activeSearchQuery 实际用于 load 时
pagination.loadedCount = 0
pagination.hasMore = true
// 然后首屏用 searchText: query
```

P0 最小正确集：

- 无搜索、全部 scope：offset 全局  
- 有搜索：独立 pagination 游标（切换 query 重置）  
- 有分组/类型：P0 可先 merge 全局页 + `refreshDisplayedItemsFromCurrentScope`；文档已知限制，P1 修

- [ ] **步骤 3：更新 `applyInitialHistoryPage` / `finishHistoryLoadingIfCurrent`**

- `applyInitialHistoryPage` 后同步 `pagination`  
- 删除或简化对 `isBulkHistoryLoading` 长时间为 true 的依赖（filter pipeline 里跳过 bulk 的分支仍可保留，但 bulk 标志应几乎总为 false）  
- `finishHistoryLoadingIfCurrent` 在仅首屏/末页时正确设置 `hasLoadedFullHistory`

- [ ] **步骤 4：更新 `refreshFirstHistoryPageForPresentation`**

使用 `pagination.pageSize` 替代硬编码 `initialVisibleItemBatchSize`（或二者同值），并写入 `pagination.loadedCount/hasMore`。

- [ ] **步骤 5：编译**

```bash
xcodebuild -scheme Clipaste -destination 'platform=macOS' build
```

预期：BUILD SUCCEEDED

- [ ] **步骤 6：Commit**

```bash
git add clipaste/ViewModels/ClipboardViewModel+Filtering.swift \
  clipaste/ViewModels/ClipboardViewModel+Presentation.swift \
  clipaste/ViewModels/ClipboardViewModel.swift
git commit -m "feat(list-perf): on-demand history pages instead of bulk full scan"
```

---

### 任务 3：横向列表 ForEach + onAppear 续页

**文件：**
- 修改：`clipaste/Views/ClipboardHorizontalView.swift`

- [ ] **步骤 1：替换 ForEach**

**Before：**

```swift
ForEach(Array(viewModel.displayedItemIDs.enumerated()), id: \.element) { index, id in
    if let item = viewModel.item(for: id) {
        ClipboardCardView(
            item: item,
            viewModel: viewModel,
            quickPasteIndex: quickPasteIndexesByItemID[id]
        )
        // ...
        .clipboardQuickPasteVisibleFrame(
            id: id,
            sourceIndex: index,
            ...
        )
    }
}
```

**After：**

```swift
ForEach(viewModel.displayedItemIDs, id: \.self) { id in
    if let item = viewModel.item(for: id) {
        ClipboardCardView(
            item: item,
            viewModel: viewModel,
            quickPasteIndex: quickPasteIndexesByItemID[id]
        )
        .id(id)
        .contentShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
        .help(pasteHelpText)
        .clipboardQuickPasteVisibleFrame(
            id: id,
            sourceIndex: 0, // 若 resolver 主要靠 frame 与 displayedItemIDs 顺序，确认 ClipboardQuickPasteVisibleFrame 是否仍需要 sourceIndex
            coordinateSpaceName: quickPasteCoordinateSpaceName,
            isTrackingEnabled: viewModel.isQuickPasteModifierHeld && !isListScrolling
        )
        .onAppear {
            viewModel.loadMoreIfNeeded(currentItemID: id)
        }
    }
}
```

实现前阅读 `ClipboardQuickPasteVisibility.swift`：若 `sourceIndex` 仍用于排序，改为：

```swift
// 在 onAppear 外无法廉价得到 index 时：
// 方案 A：resolver 忽略 sourceIndex，只用 itemIDsInDisplayOrder
// 方案 B：用 Dictionary 预计算 id→index（仅在 displayedItemIDs 变化时于 ViewModel 或 onChange 更新），避免 enumerated 全表 ForEach
```

推荐 **方案 B 轻量版**：不在 ForEach 里 enumerated，`sourceIndex` 传 `0` 并修 resolver 只依赖 `itemIDsInDisplayOrder`（若测试允许）。否则在 `onChange(of: viewModel.displayedItemIDs)` 维护 `[UUID: Int]` 索引表。

- [ ] **步骤 2：手动验证**

运行 App，打开面板，确认首屏有卡片；快速滚到右侧末尾，应触发续页且无整表卡死。

- [ ] **步骤 3：Commit**

```bash
git add clipaste/Views/ClipboardHorizontalView.swift
git commit -m "feat(list-perf): ID-only ForEach and tail-triggered loadMore"
```

---

### 任务 4：垂直列表对齐

**文件：**
- 修改：`clipaste/Views/ClipboardVerticalListView.swift`

- [ ] **步骤 1：同样使用 `ForEach(displayedItemIDs)` + `onAppear { loadMoreIfNeeded }`**

保持垂直布局的选中/preview 行为不变，只对齐数据续页与避免全量 enumerated（若存在）。

- [ ] **步骤 2：编译 + 切换横向/垂直布局各滚一次**

- [ ] **步骤 3：Commit**

```bash
git add clipaste/Views/ClipboardVerticalListView.swift
git commit -m "feat(list-perf): align vertical list with on-demand pagination"
```

---

### 任务 5：卡片 Equatable 与观察面收窄

**文件：**
- 修改：`clipaste/Views/ClipboardCardView.swift`
- 可选创建：`clipaste/Views/ClipboardCardHeaderView.swift`、`ClipboardCardContentView.swift`

- [ ] **步骤 1：为卡片增加显式渲染输入**

在保持现有 `viewModel` 仍可用于 actions（菜单/拖拽）的前提下，先做 **Equatable 包装** 减少无关键刷新：

```swift
struct ClipboardCardView: View {
    let item: ClipboardItem
    @ObservedObject var viewModel: ClipboardViewModel
    var quickPasteIndex: Int? = nil
    var isListScrolling: Bool = false

    // 从 viewModel 派生的值在 body 外由父视图传入更佳；过渡期可先内部读
}

struct ClipboardCardEquatableKey: Equatable {
    let id: UUID
    let contentHash: String
    let isSelected: Bool
    let searchHighlight: String
    let quickPasteIndex: Int?
    let isListScrolling: Bool
    let customTitle: String?
    let isPinned: Bool
}
```

父视图：

```swift
ClipboardCardView(...)
    .equatable() // 若 Card 自身 Equatable
```

实现 `static func ==` 时至少包含：`id`、`contentHash`、`isSelected`、`activeSearchQuery`、`quickPasteIndex`、`isListScrolling`、`customTitle`、`isPinned`。

**过渡策略（降低风险）：**

1. 第一刀：父视图传入 `isListScrolling`，卡片 `Equatable` 基于关键字段；仍可保留 `@ObservedObject` 但用内部 `let renderKey` + `.id(renderKey)` 或拆 `ClipboardCardChrome` 为 Equatable 子视图。  
2. 第二刀（推荐本任务完成）：父视图计算 `isSelected`/`searchHighlight` 传入；actions 用单独 monomorphic callback struct，避免整 VM 驱动 content body。

**交互必须保留的 modifier（不要删）：**

- `.clipboardContextMenu(for:viewModel:)`
- `.onDrag` / preview  
- `ClipboardCardActionModifier` / 点击粘贴  
- QuickLook anchor reporter（可评估滚动中降频）

- [ ] **步骤 2：拆分 header / content 为独立 `View` struct（不要用 @ViewBuilder 计算属性堆逻辑）**

按 `swiftui-pro` performance：独立 View 优于巨大 computed property。

- [ ] **步骤 3：滚动中抑制 RTF 新任务**

在 `refreshRichPreviewText` 开头：

```swift
if shouldDisableAnimations || isListScrolling {
    // 仅用 cache hit；miss 则保持 plain preview，不发起 prepareText
    richPreviewText = ListRenderEngine.shared.cachedText(for: item.id)
    return
}
```

Horizontal 传入 `isListScrolling: isListScrolling`。

- [ ] **步骤 4：编译并手测选中、搜索高亮、编辑标题、右键、拖拽**

- [ ] **步骤 5：Commit**

```bash
git add clipaste/Views/ClipboardCardView.swift \
  clipaste/Views/ClipboardCardHeaderView.swift \
  clipaste/Views/ClipboardCardContentView.swift \
  clipaste/Views/ClipboardHorizontalView.swift
git commit -m "perf(list): equatable card inputs and scroll-aware rich text"
```

---

### 任务 6：ImagePipeline 并发门闸

**文件：**
- 修改：`clipaste/Managers/ClipboardImagePipeline.swift`

- [ ] **步骤 1：实现简单 AsyncSemaphore（文件内 private actor 即可）**

```swift
private actor PipelineConcurrencyGate {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
        running += 1
    }

    func release() {
        running -= 1
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        }
    }
}
```

在 `ClipboardImagePipeline`：

```swift
private let decodeGate = PipelineConcurrencyGate(limit: 4)
```

在真正 `downsampleImageOffMain` / `decodeImageOffMain` 前 `await decodeGate.acquire()`，结束后 `await decodeGate.release()`（defer 注意 actor 隔离）。

- [ ] **步骤 2：快速横滑含大量图片的历史，确认无长时间卡死、图片最终仍加载**

- [ ] **步骤 3：Commit**

```bash
git add clipaste/Managers/ClipboardImagePipeline.swift
git commit -m "perf(images): limit concurrent thumbnail decodes to 4"
```

---

### 任务 7：变更通知减负

**文件：**
- 修改：`clipaste/ViewModels/ClipboardViewModel+Presentation.swift`（`setupDataSubscriptions`）

- [ ] **步骤 1：将面板打开时的 `loadData(mode: .fullRefresh)` 改为更轻模式**

```swift
// Before
self.loadData(mode: .fullRefresh)

// After
self.loadData(mode: .visibleFirst)
```

并确认 `visibleFirst` + 仅首屏 page 不会清空用户当前滚动窗口（`applyInitialHistoryPage` 已有 merge 逻辑）。若 `clipboardDataDidChange` 表示「整库替换」，可保留 fullRefresh，但 fullRefresh **仍只拉第一页 + hasMore**，不 while。

- [ ] **步骤 2：手测：复制一条新内容时列表头部插入，不整表空白重载**

- [ ] **步骤 3：Commit**

```bash
git add clipaste/ViewModels/ClipboardViewModel+Presentation.swift
git commit -m "perf(list): prefer visibleFirst on clipboard data change"
```

---

### 任务 8（P1）：分组/类型 DB 分页 API

**文件：**
- 修改：`clipaste/Managers/StorageManager.swift`（`ClipboardSearcher`）
- 修改：`clipaste/ViewModels/ClipboardViewModel+Filtering.swift` / `+Groups.swift`

- [ ] **步骤 1：扩展 Searcher**

在**不改 schema** 下增加方法，例如：

```swift
func searchAndMap(
    searchText: String,
    groupId: String?,
    typeRawValue: String?,
    fetchLimit: Int?,
    offset: Int
) async -> [ClipboardItem]
```

Predicate 组合现有字段：`groupIdsRaw` / `typeRawValue` / plainText 搜索（与今日内存 filter 语义对齐；built-in group 若逻辑复杂可先仅 user group + type）。

- [ ] **步骤 2：StorageManager 暴露 `fetchItemsPage(..., groupId:type:)`**

仍走 `detachedRead`。

- [ ] **步骤 3：ViewModel 在 `selectedGroupId` / `currentFilter` 变更时**

- bump generation  
- reset pagination  
- 首屏用新 API  
- `loadMoreIfNeeded` 带同一 scope 参数  

- [ ] **步骤 4：手测切换自定义分组与类型标签，列表完整可续页**

- [ ] **步骤 5：Commit**

```bash
git add clipaste/Managers/StorageManager.swift \
  clipaste/ViewModels/ClipboardViewModel+Filtering.swift \
  clipaste/ViewModels/ClipboardViewModel+Groups.swift
git commit -m "feat(list-perf): scoped DB pagination for groups and type filters"
```

---

### 任务 9：删除/合并时 pagination 一致性

**文件：**
- 修改：`clipaste/ViewModels/ClipboardViewModel+Items.swift` 或 `+Actions.swift`

- [ ] **步骤 1：在 `removeItems` / batch delete 后**

```swift
pagination.loadedCount = items.count
// hasMore 不变除非已知库已空
if items.isEmpty {
    pagination.hasMore = false
    hasLoadedFullHistory = true
}
```

- [ ] **步骤 2：测删除末尾附近项后仍能 loadMore**

- [ ] **步骤 3：Commit**

```bash
git add clipaste/ViewModels/ClipboardViewModel+Items.swift
git commit -m "fix(list-perf): keep pagination.loadedCount aligned after deletes"
```

---

### 任务 10：验收与回归清单

**文件：** 无代码或仅文档备注

- [ ] **步骤 1：准备 ≥500 条历史（或用现有库）**

- [ ] **步骤 2：Instruments 抽样**

| 工具 | 操作 | 期望 |
|------|------|------|
| Time Profiler | 冷开面板 | 首屏 <500ms 可感；无多秒主线程钉死 |
| Core Animation | 横滑 | 帧率 ≥55 |
| Allocations | 打开后滚一段 | 内存 <200MB 量级，不持续线性暴涨到全库 |
| 目视 | 末尾续页 | <300ms 出新卡 |

- [ ] **步骤 3：交互回归**

- [ ] 单击/双击粘贴  
- [ ] 右键菜单  
- [ ] 拖拽到外部  
- [ ] 搜索续页  
- [ ] 切换分组  
- [ ] 横/竖布局  
- [ ] 关闭再开面板（warm cache 首屏即时）

- [ ] **步骤 4：若有失败项，开 follow-up 而非放宽规格数字**

- [ ] **步骤 5：最终 commit（若有验收期小修）或 tag 说明**

```bash
git commit --allow-empty -m "chore(list-perf): record P0/P1 performance acceptance pass"
```

---

## 自检（计划 vs 规格）

| 规格需求 | 任务 |
|----------|------|
| 真·按需分页，去 while 全库 | 任务 2 |
| `loadMoreIfNeeded` + 尾部预取 | 任务 1 policy + 任务 2/3 |
| ForEach 去 enumerated | 任务 3/4 |
| 卡片 Equatable / 轻量化 | 任务 5 |
| 图片并发上限 | 任务 6 |
| 变更 fullRefresh 减负 | 任务 7 |
| 分组 DB page（P1） | 任务 8 |
| 删除与 loadedCount | 任务 9 |
| 验收标准 | 任务 10 |
| 不改 schema / 保交互 / 仅 macOS | 全文约束 |
| soft cap 淘汰（P2） | **刻意未纳入本计划**（规格 P2 可选；超内存再开） |

**占位符扫描：** 无「TODO 实现细节」；测试 target 名要求实现时用 `xcodebuild -list` 确认。  
**类型名一致性：** `HistoryPaginationState`、`HistoryPaginationPolicy.shouldLoadMore`、`loadMoreIfNeeded(currentItemID:)` 全程统一。

---

## 执行交接

计划已保存到 `docs/superpowers/plans/2026-07-27-horizontal-list-perf.md`。

**两种执行方式：**

1. **子代理驱动（推荐）** — 每任务新子代理 + 任务间审查  
2. **内联执行** — 当前会话 executing-plans，批量步骤 + 检查点  

选哪种方式？
