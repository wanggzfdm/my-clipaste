# 常驻内存优化实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 消除列表路径对 SwiftData externalStorage blob 的 fault-in，并在关面板/内存压力时回收瞬时缓存，使空闲 Physical footprint &lt; 300MB。

**架构：** 在 `ClipboardRecord` 上增加轻量 presence Bool；所有写 blob 路径同步 Bool；列表 snapshot 只读 Bool；启动分批回填；关面板与 memory pressure 清理 Image/List/AppIcon 缓存；只读 fetch 后 `modelContext.rollback()`。

**技术栈：** Swift / SwiftData / AppKit / 现有 `clipasteTests`（`@main` + `precondition`）

**规格：** `docs/superpowers/specs/2026-08-18-resident-memory-optimization-design.md`

---

## 将修改/创建的文件

| 文件 | 职责 |
|------|------|
| `clipaste/Models/ClipboardRecord.swift` | 新增 5 个 presence Bool；init 同步 |
| `clipaste/Models/ClipboardRecord+ExternalPresence.swift`（新建） | 统一 `applyExternalPresence(from:)` / `syncExternalPresenceFlags()` helper |
| `clipaste/Managers/StorageManager.swift` | upsert/merge/import/OCR/link/RTF 写路径；列表 snapshot 读 Bool；只读 fetch 后 rollback；回填 API |
| `clipaste/Managers/ClipboardRuntimeStore.swift` | 启动调度回填；可选 pressure 挂钩 |
| `clipaste/Managers/AppIconManager.swift` | `invalidateAll()` |
| `clipaste/ViewModels/ClipboardViewModel+Presentation.swift` | 关面板清三类缓存 |
| `clipaste/Services/ClipboardMemoryPressureMonitor.swift`（新建） | memory pressure → 空闲回收 |
| `clipasteTests/ClipboardExternalPresenceTests.swift`（新建） | presence / snapshot / 回填幂等 |
| `clipasteTests/ClipboardIdleCacheReleaseTests.swift`（新建） | 关面板清缓存可观测行为 |

---

### 任务 1：Record presence 字段 + 同步 helper

**文件：**
- 修改：`clipaste/Models/ClipboardRecord.swift`
- 创建：`clipaste/Models/ClipboardRecord+ExternalPresence.swift`
- 测试：`clipasteTests/ClipboardExternalPresenceTests.swift`

- [x] **步骤 1：编写失败测试（helper 语义）**

创建 `clipasteTests/ClipboardExternalPresenceTests.swift`，采用与现有测试相同的 `@main` + `precondition` 风格：

```swift
import Foundation

@main
struct ClipboardExternalPresenceTests {
    static func main() {
        testSyncFlagsFromNonEmptyBlobs()
        testSyncFlagsFromNilBlobs()
        print("ClipboardExternalPresenceTests: helper cases need implementation")
    }

    private static func testSyncFlagsFromNonEmptyBlobs() {
        // 使用纯 helper（不依赖 ModelContainer）：
        // var flags = ExternalPresenceFlags()
        // flags.update(preview: Data([1]), image: nil, linkIcon: Data([2]), rtf: nil, archive: Data([3]))
        // precondition(flags.hasPreviewImageData)
        // precondition(flags.hasOriginalImageData == false)
        // precondition(flags.hasLinkIconData)
        // precondition(flags.hasRTFData == false)
        // precondition(flags.hasRichTextArchiveData)
        precondition(false, "ExternalPresenceFlags not implemented")
    }

    private static func testSyncFlagsFromNilBlobs() {
        precondition(false, "ExternalPresenceFlags clear path not implemented")
    }
}
```

- [x] **步骤 2：实现 `ExternalPresenceFlags` + Record 扩展**

`ClipboardRecord+ExternalPresence.swift`：

```swift
import Foundation

struct ExternalPresenceFlags: Equatable, Sendable {
    var hasPreviewImageData = false
    var hasOriginalImageData = false
    var hasLinkIconData = false
    var hasRTFData = false
    var hasRichTextArchiveData = false

    mutating func update(
        preview: Data?,
        image: Data?,
        linkIcon: Data?,
        rtf: Data?,
        archive: Data?
    ) {
        hasPreviewImageData = Self.isPresent(preview)
        hasOriginalImageData = Self.isPresent(image)
        hasLinkIconData = Self.isPresent(linkIcon)
        hasRTFData = Self.isPresent(rtf)
        hasRichTextArchiveData = Self.isPresent(archive)
    }

    static func isPresent(_ data: Data?) -> Bool {
        guard let data else { return false }
        return data.isEmpty == false
    }
}

extension ClipboardRecord {
    func apply(_ flags: ExternalPresenceFlags) {
        hasPreviewImageData = flags.hasPreviewImageData
        hasOriginalImageData = flags.hasOriginalImageData
        hasLinkIconData = flags.hasLinkIconData
        hasRTFData = flags.hasRTFData
        hasRichTextArchiveData = flags.hasRichTextArchiveData
    }

    /// 仅回填/调试路径：从 blob 重算 flags（会 fault-in）。
    func resyncExternalPresenceFlagsFromBlobs() {
        var flags = ExternalPresenceFlags()
        flags.update(
            preview: previewImageData,
            image: imageData,
            linkIcon: linkIconData,
            rtf: rtfData,
            archive: richTextArchiveData
        )
        apply(flags)
    }

    func setPreviewImageDataKeepingPresence(_ data: Data?) {
        previewImageData = data
        hasPreviewImageData = ExternalPresenceFlags.isPresent(data)
    }

    func setOriginalImageDataKeepingPresence(_ data: Data?) {
        imageData = data
        hasOriginalImageData = ExternalPresenceFlags.isPresent(data)
    }

    func setLinkIconDataKeepingPresence(_ data: Data?) {
        linkIconData = data
        hasLinkIconData = ExternalPresenceFlags.isPresent(data)
    }

    func setRTFDataKeepingPresence(_ data: Data?) {
        rtfData = data
        hasRTFData = ExternalPresenceFlags.isPresent(data)
    }

    func setRichTextArchiveDataKeepingPresence(_ data: Data?) {
        richTextArchiveData = data
        hasRichTextArchiveData = ExternalPresenceFlags.isPresent(data)
    }
}
```

在 `ClipboardRecord` 增加 5 个 `Bool` 属性（默认 `false`），并在 `init` 末尾根据传入的 Data 调用 `apply`。

- [x] **步骤 3：跑 helper 测试通过**

```bash
# 按仓库现有方式编译/运行 clipasteTests target；若无统一脚本则用 xcodebuild
xcodebuild -scheme Clipaste -destination 'platform=macOS' build-for-testing
# 或直接编译运行 ClipboardExternalPresenceTests 可执行文件
```

- [x] **步骤 4：Commit**

```bash
git add clipaste/Models/ClipboardRecord.swift \
  clipaste/Models/ClipboardRecord+ExternalPresence.swift \
  clipasteTests/ClipboardExternalPresenceTests.swift
git commit -m "feat(memory): add external blob presence flags on ClipboardRecord"
```

---

### 任务 2：所有写路径同步 presence

**文件：**
- 修改：`clipaste/Managers/StorageManager.swift`（`ClipboardStoreActor` 内所有 blob 赋值）
- 检索确认：全工程 `previewImageData =` / `imageData =` / `rtfData =` / `linkIconData =` / `richTextArchiveData =`

- [x] **步骤 1：把直接赋值改为 `set*KeepingPresence`**

至少覆盖：

- `upsert` 中 `previewImageData` / `imageData` / `rtf`/`archive`（含 `refreshStoredTextRepresentations`）
- `updateRecordWithLinkMetadata` 的 `linkIconData`
- `updateRecordWithRTFData` / 文本编辑路径清空或重写 RTF
- import/merge（`merge(_:into:)`、`import` 构造 `ClipboardRecord`）
- 任何 `record.rtfData = nil` 清空路径

原则：

```swift
// BAD
existingRecord.previewImageData = previewImageData
// GOOD
existingRecord.setPreviewImageDataKeepingPresence(previewImageData)
```

新建 `ClipboardRecord(...)` 时 init 已根据 Data 设 flag；若 init 后再次改 blob 必须走 setter。

- [x] **步骤 2：全库检索无遗漏**

```bash
# 实现后人工/检索确认：除 setter 与 resync 外，无直接 blob 赋值
```

- [x] **步骤 3：补充测试 — upsert 后 flag 正确**

若测试可起临时 `ModelContainer`（in-memory），增加用例：upsert 带 `imageData` → fetch 后 `hasOriginalImageData == true` 且列表 snapshot 不需读 blob。若容器启动成本高，至少保持 helper 单测 + 代码审查清单。

- [x] **步骤 4：Commit**

```bash
git commit -m "fix(memory): keep presence flags in sync on all blob writes"
```

---

### 任务 3：列表 snapshot 禁止 fault-in

**文件：**
- 修改：`clipaste/Managers/StorageManager.swift`（两处 snapshot 构建：~163 与 ~998）

- [x] **步骤 1：替换 nil 检查**

```swift
// BEFORE
hasPreviewImage: record.previewImageData != nil,
hasImageData: record.imageData != nil,
hasLinkIcon: record.linkIconData != nil,
hasRTF: record.rtfData != nil || record.richTextArchiveData != nil,

// AFTER
hasPreviewImage: record.hasPreviewImageData,
hasImageData: record.hasOriginalImageData,
hasLinkIcon: record.hasLinkIconData,
hasRTF: record.hasRTFData || record.hasRichTextArchiveData,
```

- [x] **步骤 2：工程内检索禁止模式**

确保 **列表/DTO 映射路径** 不再出现：

- `previewImageData != nil`
- `imageData != nil`（Record 上）
- `linkIconData != nil`
- `rtfData != nil`
- `richTextArchiveData != nil`

按需 load API 保留对 blob 的读取。

- [x] **步骤 3：只读列表 fetch 后 rollback**

在 `fetchItems`（及 warm-cache 用的只读分页）映射完成后：

```swift
let items = records.map { ... }
modelContext.rollback() // 丢弃只读 fault 注册，降低常驻
return items
```

注意：不得在同一函数未 `save` 的写逻辑后调用。

- [x] **步骤 4：Commit**

```bash
git commit -m "fix(memory): list snapshots use presence flags without faulting blobs"
```

---

### 任务 4：分批回填迁移

**文件：**
- 修改：`clipaste/Managers/StorageManager.swift`（actor 方法）
- 修改：`clipaste/Managers/ClipboardRuntimeStore.swift`（激活后调度）

- [x] **步骤 1：实现 backfill**

```swift
// ClipboardStoreActor
func backfillExternalPresenceFlags(batchSize: Int = 48) -> Int {
    let defaultsKey = "clipboard_external_presence_backfill_v1"
    // 若外层已标记完成可直接 return 0
    var total = 0
    var offset = 0
    while true {
        var descriptor = FetchDescriptor<ClipboardRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        descriptor.fetchLimit = batchSize
        descriptor.fetchOffset = offset
        let batch = (try? modelContext.fetch(descriptor)) ?? []
        if batch.isEmpty { break }
        var changed = 0
        for record in batch {
            let before = ExternalPresenceFlags(
                hasPreviewImageData: record.hasPreviewImageData,
                hasOriginalImageData: record.hasOriginalImageData,
                hasLinkIconData: record.hasLinkIconData,
                hasRTFData: record.hasRTFData,
                hasRichTextArchiveData: record.hasRichTextArchiveData
            )
            record.resyncExternalPresenceFlagsFromBlobs()
            let after = ExternalPresenceFlags(
                hasPreviewImageData: record.hasPreviewImageData,
                hasOriginalImageData: record.hasOriginalImageData,
                hasLinkIconData: record.hasLinkIconData,
                hasRTFData: record.hasRTFData,
                hasRichTextArchiveData: record.hasRichTextArchiveData
            )
            if before != after { changed += 1 }
        }
        if changed > 0 { try? modelContext.save() }
        modelContext.rollback()
        total += changed
        offset += batch.count
        if batch.count < batchSize { break }
    }
    return total
}
```

- [x] **步骤 2：Runtime 调度**

在 runtime 激活成功且本地 store 可用后：

```swift
Task.detached(priority: .utility) {
    let key = "clipboard_external_presence_backfill_v1"
    guard UserDefaults.standard.bool(forKey: key) == false else { return }
    let fixed = await StorageManager.shared.backfillExternalPresenceFlags()
    UserDefaults.standard.set(true, forKey: key)
    // 可选：debug log fixed count
}
```

- [x] **步骤 3：测试幂等**

单元测试：构造 flags 与 blob 不一致 → backfill 一次纠正 → 第二次 changed==0（可用 in-memory container 或纯逻辑模拟）。

- [x] **步骤 4：Commit**

```bash
git commit -m "feat(memory): backfill external presence flags in batches"
```

---

### 任务 5：关面板与 AppIcon 缓存回收

**文件：**
- 修改：`clipaste/Managers/AppIconManager.swift`
- 修改：`clipaste/ViewModels/ClipboardViewModel+Presentation.swift`
- 测试：`clipasteTests/ClipboardIdleCacheReleaseTests.swift`

- [x] **步骤 1：AppIconManager.invalidateAll**

```swift
func invalidateAll() {
    cache.removeAllObjects()
}
```

- [x] **步骤 2：扩展 releaseTransientResourcesAfterPanelClose**

在现有逻辑开头或裁剪前：

```swift
ClipboardImagePipeline.shared.invalidateAll()
ListRenderEngine.shared.invalidateAll()
AppIconManager.shared.invalidateAll()
```

保留 warm cache / lastScopeSnapshot。

- [x] **步骤 3：可测性（如需）**

若 NSCache 不便断言，可为 pipeline/engine 增加 `debugCachedCount`（`#if DEBUG`）或测试专用 hook；至少保证 `invalidateAll` 可调用且无崩溃。

- [x] **步骤 4：Commit**

```bash
git commit -m "fix(memory): drop image/text/icon caches when panel closes"
```

---

### 任务 6：Memory pressure 监听

**文件：**
- 创建：`clipaste/Services/ClipboardMemoryPressureMonitor.swift`
- 修改：`clipaste/Managers/ClipboardRuntimeStore.swift` 或 `clipasteApp.swift` 启动处

- [x] **步骤 1：实现 monitor**

```swift
import Foundation
import Dispatch

@MainActor
final class ClipboardMemoryPressureMonitor {
    static let shared = ClipboardMemoryPressureMonitor()
    private var source: DispatchSourceMemoryPressure?

    func start() {
        guard source == nil else { return }
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            self?.handlePressure(src.data)
        }
        src.resume()
        source = src
    }

    private func handlePressure(_ events: DispatchSource.MemoryPressureEvent) {
        // 面板打开且仅 warning：可跳过缩略图清理以免闪烁
        // critical 或面板未展示：清理三类缓存
        NotificationCenter.default.post(name: .clipboardMemoryPressure, object: nil)
    }
}

extension Notification.Name {
    static let clipboardMemoryPressure = Notification.Name("clipboardMemoryPressure")
}
```

- [x] **步骤 2：ViewModel / Runtime 订阅**

空闲时执行与关面板相同的 cache invalidate；可选触发 storage 只读 context 减压 API。

- [x] **步骤 3：Commit**

```bash
git commit -m "feat(memory): release caches under system memory pressure"
```

---

### 任务 7：验收与回归

- [x] **步骤 1：单元测试全绿**

运行 `ClipboardExternalPresenceTests`、`ClipboardIdleCacheReleaseTests`、现有 scope cache 测试。

- [x] **步骤 2：本机内存验收**

```bash
# 构建安装 Debug/Release 后
# 1) 冷启动，面板关闭，等待 2–5 分钟
vmmap -summary <pid> | head -40
heap -sortBySize <pid> | head -40
# 期望：Physical footprint < 300MB
# 期望：_PFExternalReferenceData._bytesPtrForStore 不再数百 MB

# 2) 打开面板，滚动含图历史，关闭 30s 再采一次
```

- [x] **步骤 3：功能回归清单**

- [ ] 图片卡片缩略图
- [ ] QuickLook 大图
- [ ] 复制/粘贴原图
- [ ] OCR
- [ ] 富文本卡片预览
- [ ] 链接 favicon
- [ ] 关面板再开：首屏 warm cache 仍快

- [x] **步骤 4：最终 commit（若有修）**

```bash
git commit -m "test(memory): cover presence flags and idle cache release"
```

---

## 风险检查清单（实现时）

- 回填完成前旧数据 Bool 全 false → 图/RTF 入口可能暂时消失：回填应在启动早期 utility 优先级尽快跑完；或首版在回填完成前对 `contentType == .image` 保守显示 `hasImageData = true`（仅类型启发式，不读 blob）。
- `rollback` 仅用于只读 fetch。
- CloudKit 同步合并路径必须写 presence，否则云端下来的记录列表缺标记。

---

## 完成定义

1. 规格中的空闲 &lt; 300MB 在本机可复现（heap 主因消失）  
2. 列表路径无 external `*Data != nil`  
3. 关面板清三类缓存  
4. 相关测试通过 + 功能回归通过  
