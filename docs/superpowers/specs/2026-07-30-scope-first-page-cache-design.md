# 分组切换首屏缓存设计

## 背景

当前分组切换会先过滤内存中的 `items`，随后调用 SwiftData 分页查询。未命中内存时，用户需要等待 DB 首屏；DB 返回后还会执行 `mergeItems`、替换 `displayedItemIDs` 并再次递增 `listContentEpoch`，导致 SwiftUI 横向列表整树重建。

目标是在不牺牲 DB 最终一致性的前提下，让已经访问过的分组再次切换时立即显示，同时避免 DB 校正阶段重复重建列表。

## 目标与非目标

### 目标

1. 为全部、用户分组、类型过滤、收藏和搜索 scope 缓存最近一次 DB 首屏。
2. 切换 scope 时按以下优先级立即展示：scope 首屏缓存 > 当前内存过滤结果 > 保留旧列表并显示加载状态。
3. 无论是否命中缓存，都继续发起 DB 首屏查询，确保数据最终按最新时间和分组关系校正。
4. DB 返回后只在当前 scope 仍有效时更新展示和缓存；快速连续切换不能让旧查询覆盖新 scope。
5. 一个用户操作只触发一次列表身份重建；DB 校正不再额外 bump `listContentEpoch`。
6. 为 scope key、缓存命中与校正逻辑提供可测试的纯逻辑边界。

### 非目标

- 不把全部历史预加载到内存。
- 不修改 `openStateItemSoftCap`。
- 不引入第三方缓存库。
- 不改变卡片内容和分组数据模型。
- 不在本次重构 SwiftUI 的 `ObservableObject` 数据流。

## 设计

### Scope 标识

新增 `ClipboardScopeKey: Hashable`，由规范化后的搜索词和当前展示条件组成：

- `.all(query:)`
- `.group(query:, id:)`
- `.type(query:, rawValue:)`
- `.pinned(query:)`

同一个 scope 的缓存只由完整 key 命中，避免不同搜索词、分组或过滤器共享错误首屏。

### 缓存条目

新增 `ClipboardScopeSnapshot`，保存：

- `items: [ClipboardItem]`：首屏所需的轻量 UI DTO；图片数据仍不随列表常驻加载。
- `displayedIDs: [UUID]`：DB 返回顺序。
- `loadedCount: Int`：对应分页游标位置。
- `hasMore: Bool`：是否存在后续页。
- `updatedAt: Date`：用于有限容量淘汰和诊断。

ViewModel 维护有限容量的内存字典，容量固定为最近 8 个 scope。插入新条目时淘汰最旧条目，避免访问很多分组后无限持有 DTO。

### 切换数据流

`activateDisplayedScope` 先更新 scope 状态并执行一次动画抑制，然后调用统一的即时展示方法：

1. 生成当前 `ClipboardScopeKey`。
2. 若缓存命中，将快照 items 合并到 `items`，立即发布快照 IDs，并恢复该 scope 的分页状态。
3. 缓存未命中时，使用现有 `applyMemoryScopePreferringNonEmptyDisplay()` 对内存过滤；若有结果立即发布。
4. 两者都未命中时保持旧列表，设置 loading，不让界面经历 Empty → List 的插入动画。
5. 启动现有 `beginScopePagination` / `loadData` 进行 DB 校正。

缓存命中不是终止条件，DB 请求仍然发送。这样缓存负责首帧体验，DB 负责时间、分组归属和删除状态的正确性。

### DB 校正

DB 首屏返回后：

1. 先检查 generation 和当前 scope key；过期结果直接丢弃。
2. 将 DB 页写入对应 scope snapshot。
3. 合并 DB 页到全局 `items`，去重并维持时间顺序。
4. 在关闭动画的 transaction 内发布新的 `displayedItemIDs`。
5. 不再调用 `noteListContentReplacedWithoutAnimation()`；scope 切换时已经完成一次 `listContentEpoch` bump，DB 回来只更新 ID，不重复重建 LazyHStack。
6. 更新分页状态，后续滚动仍沿用当前 scope 的 offset。

全部 scope 也使用同一缓存路径。切回全部时，缓存首屏先显示，随后执行 DB `fullRefresh`；DB 返回后用最新页替换/校正缓存，不沿用上一分组的 IDs。

### 并发与失效

- `dataLoadGeneration` 仍是 DB 请求的主防线。
- 缓存写入必须绑定 scope key；只允许当前请求的 key 写入对应缓存。
- 发生 clipboard 数据变化时不主动清空全部缓存；下一次 DB 校正会覆盖当前 scope。当前内存中的 optimistic capture 仍可立即更新全部 scope。
- 分组删除、重命名和分组归属修改后，删除对应 group key 的缓存；全部和其它 scope 保留，避免无关分组失去热缓存。
- 面板关闭时清理 scope 缓存，仅保留现有的全部 scope snapshot，控制内存占用；再次打开从 warm cache 恢复。

## 测试策略

新增纯逻辑测试覆盖：

1. 完整 `ScopeKey` 的不同条件不会相互命中。
2. 缓存命中时优先返回快照，未命中时回退到内存过滤。
3. 超过容量后只淘汰最旧条目。
4. 旧 generation 的 DB 结果不能覆盖当前 scope。
5. DB 校正后的 IDs 去重并保持 DB 顺序。

若当前 Xcode 工程没有测试 target，则先在 `clipaste.xcodeproj` 增加 `ClipasteTests` target，并只测试独立的缓存/排序逻辑，不依赖 SwiftData、AppKit 窗口或 SwiftUI 渲染。

## 验收标准

- 第二次切换到已访问分组时，首帧直接显示上次首屏，不出现空列表等待。
- 第一次切换冷分组时，不出现 Empty → List 飞入；DB 返回后无动画更新。
- 快速连续切换 A → B 时，A 的 DB 结果不会覆盖 B。
- 切回全部仍能得到 DB 最新首屏。
- 缓存容量有限，关闭面板后不会保留所有分组数据。
- `xcodebuild build` 和新增测试 target 全部通过。
