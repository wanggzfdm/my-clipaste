# 分组切换首屏缓存实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 让已访问分组在切换时立即显示最近首屏，同时让 SwiftData 在后台校正且不重复重建 SwiftUI 列表。

**架构：** 在 ViewModel 外增加无 UI 依赖的 `ClipboardScopeCache`，以完整 scope key 管理有限容量首屏快照；`ClipboardViewModel` 在 scope 切换时先恢复缓存/内存结果，再发起现有分页请求。DB 返回只更新当前 scope 的 IDs、全局 item 索引和缓存，不再第二次 bump `listContentEpoch`。

**技术栈：** Swift 6 concurrency、SwiftUI、SwiftData、XCTest、Xcode project file-system synchronized groups。

---

### 任务 1：建立 scope key 与有限容量缓存的失败测试

**文件：**
- 创建：`clipasteTests/ClipboardScopeCacheTests.swift`
- 创建：`clipaste/ViewModels/ClipboardScopeCache.swift`（测试前只放最小类型声明；实现步骤中完整替换）
- 修改：`clipaste.xcodeproj/project.pbxproj`（添加 `ClipasteTests` unit-test target）

- [ ] **步骤 1：添加测试 target 和失败测试**

测试必须只依赖 `Foundation` 与缓存类型，不启动 SwiftData 或 SwiftUI：

```swift
import XCTest
@testable import Clipaste

final class ClipboardScopeCacheTests: XCTestCase {
    func testDifferentScopeAttributesDoNotShareSnapshot() {
        let cache = ClipboardScopeCache(capacity: 8)
        let groupKey = ClipboardScopeKey.group(query: "", id: "components")
        let typeKey = ClipboardScopeKey.type(query: "", rawValue: "text")

        cache.insert(makeSnapshot(id: UUID()), for: groupKey)

        XCTAssertNil(cache.snapshot(for: typeKey))
    }

    func testCacheEvictsLeastRecentlyUsedSnapshotAfterCapacity() {
        let cache = ClipboardScopeCache(capacity: 2)
        let first = ClipboardScopeKey.all(query: "")
        let second = ClipboardScopeKey.type(query: "", rawValue: "text")
        let third = ClipboardScopeKey.pinned(query: "")

        cache.insert(makeSnapshot(id: UUID()), for: first)
        cache.insert(makeSnapshot(id: UUID()), for: second)
        _ = cache.snapshot(for: first)
        cache.insert(makeSnapshot(id: UUID()), for: third)

        XCTAssertNotNil(cache.snapshot(for: first))
        XCTAssertNil(cache.snapshot(for: second))
        XCTAssertNotNil(cache.snapshot(for: third))
    }

    private func makeSnapshot(id: UUID) -> ClipboardScopeSnapshot {
        ClipboardScopeSnapshot(
            items: [ClipboardItem(contentHash: id.uuidString, textPreview: "cached", appName: "Test", appIconName: "doc")],
            itemIDs: [id],
            loadedCount: 1,
            hasMore: false,
            updatedAt: Date()
        )
    }
}
```

- [ ] **步骤 2：运行测试确认失败**

运行：

```bash
xcodebuild test -project clipaste.xcodeproj -scheme Clipaste -destination 'platform=macOS'
```

预期：FAIL，原因是 `ClipasteTests` target / `ClipboardScopeCache` 尚未定义，而不是编译环境错误。

- [ ] **步骤 3：Commit**

```bash
git add clipasteTests clipaste.xcodeproj/project.pbxproj clipaste/ViewModels/ClipboardScopeCache.swift
git commit -m "test: define scope cache behavior"
```

### 任务 2：实现 scope key、快照与 LRU 缓存

**文件：**
- 修改：`clipaste/ViewModels/ClipboardScopeCache.swift`
- 测试：`clipasteTests/ClipboardScopeCacheTests.swift`

- [ ] **步骤 1：实现最小可用类型**

```swift
import Foundation

struct ClipboardScopeSnapshot: Sendable {
    let items: [ClipboardItem]
    let itemIDs: [UUID]
    let loadedCount: Int
    let hasMore: Bool
    let updatedAt: Date
}

enum ClipboardScopeKey: Hashable, Sendable {
    case all(query: String)
    case group(query: String, id: String)
    case type(query: String, rawValue: String)
    case pinned(query: String)
}

@MainActor
final class ClipboardScopeCache {
    private struct Entry {
        var snapshot: ClipboardScopeSnapshot
        var lastAccess: UInt64
    }

    private let capacity: Int
    private var nextAccess: UInt64 = 0
    private var entries: [ClipboardScopeKey: Entry] = [:]

    init(capacity: Int = 8) {
        self.capacity = max(capacity, 1)
    }

    func snapshot(for key: ClipboardScopeKey) -> ClipboardScopeSnapshot? {
        guard var entry = entries[key] else { return nil }
        nextAccess &+= 1
        entry.lastAccess = nextAccess
        entries[key] = entry
        return entry.snapshot
    }

    func insert(_ snapshot: ClipboardScopeSnapshot, for key: ClipboardScopeKey) {
        nextAccess &+= 1
        entries[key] = Entry(snapshot: snapshot, lastAccess: nextAccess)
        trimIfNeeded()
    }

    func remove(where predicate: (ClipboardScopeKey) -> Bool) {
        entries.keys.filter(predicate).forEach { entries.removeValue(forKey: $0) }
    }

    func removeAll(keeping predicate: (ClipboardScopeKey) -> Bool) {
        entries.keys.filter { !predicate($0) }.forEach { entries.removeValue(forKey: $0) }
    }

    private func trimIfNeeded() {
        while entries.count > capacity,
              let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            entries.removeValue(forKey: oldest)
        }
    }
}
```

- [ ] **步骤 2：运行缓存测试确认通过**

```bash
xcodebuild test -project clipaste.xcodeproj -scheme Clipaste -destination 'platform=macOS' -only-testing:ClipasteTests/ClipboardScopeCacheTests
```

预期：缓存相关测试 PASS。

- [ ] **步骤 3：Commit**

```bash
git add clipaste/ViewModels/ClipboardScopeCache.swift clipasteTests/ClipboardScopeCacheTests.swift
git commit -m "feat: add bounded scope first-page cache"
```

### 任务 3：接入 ViewModel 的 scope key、缓存恢复与缓存写入

**文件：**
- 修改：`clipaste/ViewModels/ClipboardViewModel.swift`
- 修改：`clipaste/ViewModels/ClipboardViewModel+Groups.swift`
- 修改：`clipaste/ViewModels/ClipboardViewModel+Filtering.swift`
- 修改：`clipaste/ViewModels/ClipboardViewModel+Presentation.swift`
- 测试：`clipasteTests/ClipboardScopeCacheTests.swift`

- [ ] **步骤 1：先添加 ViewModel 行为失败测试辅助 API**

新增纯函数/策略方法，使测试不需要启动 SwiftData：

```swift
func scopeCacheKey(
    query: String,
    groupID: String?,
    type: ClipboardContentType?,
    builtInGroup: ClipboardBuiltInGroup?
) -> ClipboardScopeKey
```

测试覆盖：空白 query 会被 trim，同一 scope 的不同输入组合生成不同 key。

- [ ] **步骤 2：运行新增测试确认失败**

```bash
xcodebuild test -project clipaste.xcodeproj -scheme Clipaste -destination 'platform=macOS' -only-testing:ClipasteTests/ClipboardScopeCacheTests
```

预期：FAIL，原因是 ViewModel 尚未暴露 scope key 生成策略。

- [ ] **步骤 3：添加缓存状态与 scope key 生成**

在 `ClipboardViewModel` 中添加：

```swift
let scopeCache = ClipboardScopeCache()
var activeScopeCacheKey: ClipboardScopeKey?
```

实现 `scopeCacheKey(...)`，并在 `activateDisplayedScope` 更新当前 key。搜索、分组、类型、收藏和全部都必须包含规范化 query。

- [ ] **步骤 4：把缓存恢复接入即时展示路径**

在 `applyMemoryScopePreferringNonEmptyDisplay()` 前先调用 `restoreScopeSnapshotIfAvailable()`：

```swift
private func restoreScopeSnapshotIfAvailable() -> Bool {
    guard let key = activeScopeCacheKey,
          let snapshot = scopeCache.snapshot(for: key) else { return false }

    mergeItems(snapshot.items, prepend: true, enqueueLinkMetadata: false)
    publishDisplayedItemIDs(snapshot.itemIDs)
    pagination.loadedCount = snapshot.loadedCount
    pagination.hasMore = snapshot.hasMore
    pagination.isLoading = true
    isInitialHistoryLoading = false
    isLoadingMoreHistory = true
    reconcileSelectionAfterDisplayedItemsChange()
    return true
}
```

实际条目快照需要同时保存 `items: [ClipboardItem]`；`itemIDs` 只负责顺序，不能让 UI 依赖已经被 soft cap 淘汰的 item。

- [ ] **步骤 5：在 DB 首屏返回后写入缓存**

在 `beginPagedFetch` 的返回闭包中捕获 `requestKey`，并在 generation 校验通过后保存 DB 页：

```swift
let requestKey = scopeCacheKey(
    query: query,
    groupID: groupId,
    type: typeRawValue.flatMap(ClipboardContentType.init(rawValue:)),
    builtInGroup: pinnedOnly ? .favorites : nil
)
```

缓存快照使用 DB 页顺序、页条目、`loadedCount: page.count` 与 `hasMore: page.count == pageSize`。如果当前 key 已变化，允许丢弃展示更新，也不能把结果写进别的 key。

- [ ] **步骤 6：运行缓存与 ViewModel 测试确认通过**

```bash
xcodebuild test -project clipaste.xcodeproj -scheme Clipaste -destination 'platform=macOS' -only-testing:ClipasteTests/ClipboardScopeCacheTests
```

预期：全部 PASS。

- [ ] **步骤 7：Commit**

```bash
git add clipaste/ViewModels/ClipboardViewModel.swift clipaste/ViewModels/ClipboardViewModel+Groups.swift clipaste/ViewModels/ClipboardViewModel+Filtering.swift clipaste/ViewModels/ClipboardViewModel+Presentation.swift clipasteTests/ClipboardScopeCacheTests.swift
git commit -m "feat: restore cached scope pages before refresh"
```

### 任务 4：移除 DB 校正阶段的第二次列表整树重建

**文件：**
- 修改：`clipaste/ViewModels/ClipboardViewModel+Filtering.swift:applyInitialHistoryPage`
- 修改：`clipaste/ViewModels/ClipboardViewModel+Groups.swift:activateDisplayedScope`
- 修改：`clipaste/ViewModels/ClipboardViewModel+Scroll.swift`（仅必要时）
- 修改：`clipaste/Views/ClipboardHorizontalView.swift`（仅必要时）

- [ ] **步骤 1：添加 stale generation / 当前 scope 的失败测试**

测试策略方法：

```swift
func shouldApplyScopeResult(
    resultGeneration: UInt,
    currentGeneration: UInt,
    resultKey: ClipboardScopeKey,
    currentKey: ClipboardScopeKey
) -> Bool {
    resultGeneration == currentGeneration && resultKey == currentKey
}
```

覆盖 A → B 后 A 返回必须为 false。

- [ ] **步骤 2：运行测试确认失败**

```bash
xcodebuild test -project clipaste.xcodeproj -scheme Clipaste -destination 'platform=macOS' -only-testing:ClipasteTests/ClipboardScopeCacheTests
```

预期：FAIL，原因是校验策略尚未存在。

- [ ] **步骤 3：实现校验并调整页面应用流程**

在 DB 返回处同时检查 generation 和当前 key。`applyInitialHistoryPage` 保留首次加载或没有既有 scope 抑制时的 `noteListContentReplacedWithoutAnimation()`，但当 scope 切换已经调用过 `beginScopeSwitchAnimationSuppression()` 时，不再递增 `listContentEpoch`。

DB 页更新展示时使用一个禁用动画 transaction：

```swift
var transaction = Transaction()
transaction.disablesAnimations = true
transaction.animation = nil
withTransaction(transaction) {
    publishDisplayedItemIDs(page.map(\.id))
    reconcileSelectionAfterDisplayedItemsChange()
}
```

保留 `listContentEpoch` 的单次 bump，避免改变现有 Empty/List 动画防护行为。

- [ ] **步骤 4：运行测试和构建**

```bash
xcodebuild test -project clipaste.xcodeproj -scheme Clipaste -destination 'platform=macOS' -only-testing:ClipasteTests/ClipboardScopeCacheTests
xcodebuild build -project clipaste.xcodeproj -scheme Clipaste -configuration Debug -destination 'platform=macOS'
```

预期：测试 PASS，build exit 0。

- [ ] **步骤 5：Commit**

```bash
git add clipaste/ViewModels/ClipboardViewModel+Filtering.swift clipaste/ViewModels/ClipboardViewModel+Groups.swift clipaste/ViewModels/ClipboardViewModel+Scroll.swift clipaste/Views/ClipboardHorizontalView.swift clipasteTests/ClipboardScopeCacheTests.swift
 git commit -m "perf: avoid rebuilding list during scope refresh"
```

### 任务 5：缓存失效、面板关闭清理与完整验证

**文件：**
- 修改：`clipaste/ViewModels/ClipboardViewModel+Groups.swift`
- 修改：`clipaste/ViewModels/ClipboardViewModel+Presentation.swift`
- 修改：`clipaste/ViewModels/ClipboardViewModel+Items.swift`（如分组归属修改路径需要）
- 修改：`clipaste/ViewModels/ClipboardViewModel+Filtering.swift`
- 测试：`clipasteTests/ClipboardScopeCacheTests.swift`

- [ ] **步骤 1：添加缓存失效测试**

覆盖：删除指定分组缓存不影响全部 scope；面板关闭清理除全部 scope 之外的条目。

- [ ] **步骤 2：运行测试确认失败**

```bash
xcodebuild test -project clipaste.xcodeproj -scheme Clipaste -destination 'platform=macOS' -only-testing:ClipasteTests/ClipboardScopeCacheTests
```

预期：FAIL，原因是失效策略尚未接入。

- [ ] **步骤 3：实现失效策略**

- 删除/修改分组时移除对应 `.group` key。
- 面板关闭时保留 `.all` key，并清理其它 scope，避免长期持有分组 DTO。
- clipboard 数据变更不全量清空缓存，依赖下一次 DB 校正；若当前是全部 scope，沿用已有 warm cache/optimistic capture 更新。

- [ ] **步骤 4：运行完整验证**

```bash
xcodebuild test -project clipaste.xcodeproj -scheme Clipaste -destination 'platform=macOS'
xcodebuild build -project clipaste.xcodeproj -scheme Clipaste -configuration Debug -destination 'platform=macOS'
git diff --check
```

预期：测试全部 PASS、build exit 0、`git diff --check` 无输出。

- [ ] **步骤 5：检查最终 diff 并 Commit**

```bash
git status --short
git diff --stat
git add clipaste clipasteTests clipaste.xcodeproj/project.pbxproj
git commit -m "perf: cache clipboard scope first pages"
```
