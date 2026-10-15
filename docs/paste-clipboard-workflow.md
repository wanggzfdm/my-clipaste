# Paste 剪切板完整工作算法（实证还原）

> 本文档基于 **rea + Ghidra 12.1.4** 对 Paste.app 主程序（arm64，`/tmp/paste_arm64`）Swift 符号的反编译，还原 Paste 从「系统剪切板 → 捕获 → 去重 → 存储 → 加载 → 搜索 → 粘贴」的完整工作算法。供 Clipaste 参考对齐。
> 关键符号：`PasteCore.Pasteboard`、`PasteboardHistoryManager`、`PasteboardItem`、`PasteboardWriter`、`PasteboardItemComposer/Processor`、`ItemEntity`、`SearchableItemEntity`。

---

## 1. 总览：数据流

```
NSPasteboard.general
   │  (0.3s 防抖定时轮询 changeCount)
   ▼
Pasteboard.handlePollTimer:  →  检测 changeCount 变化 → 调度 0.3s 防抖 Timer
   ▼ (Timer 触发)
PasteboardHistoryManager.sync(from:):  前台应用 → 读 items → 逐类型读 Data → 去重 → PasteboardItem
   ▼ (CoreData)
ItemEntity (ZITEMENTITY 轻量列)  +  ZITEMDATAENTITY (原始 pasteboard 内容 BLOB)
   │  checksum 去重 / timestamp 降序排序
   ▼ (NSFetchedResultsController + DiffableDataSource)
历史列表 UI  ←  itemsPublisher (Combine CurrentValueSubject<[ItemEntity]>)
   ▼ (SearchableItemEntity / CoreSpotlight)
全文搜索
   ▼ (NSPersistentHistoryTracking + CloudKit / CKSyncEngine)
跨设备同步
```

---

## 2. 捕获层：Pasteboard（轮询 + 防抖）

### 2.1 机制（`PasteCore.Pasteboard` 反编译）
- **不是** `NSNotificationCenter` 监听，而是**定时轮询 `NSPasteboard.general.changeCount`**。
- 核心函数 `FUN_1003a3a78`（`handlePollTimer:` 内部）伪代码：
  ```c
  self = NSPasteboard.general;
  IVar1 = changeCount(self);
  if (IVar1 != 上次记录的 changeCount) {       // 有新的复制
      处理内容(读取/存储);                        // → 触发 sync
      IVar1 = changeCount(self);
      记录新 changeCount;                        // 对象偏移 +0x30
      if (旧Timer) invalidate(旧Timer);          // 取消旧定时器
      新Timer = scheduledTimerWithTimeInterval(NSTimer, 0.3s);  // 0x3fd3333333333333
      记录新Timer;                               // 对象偏移 +0x40
  }
  ```
- **防抖合并**：检测到变化后先 `invalidate` 旧定时器、再调度新的 **0.3 秒** 定时器。连续快速复制会不断重置定时器，把多次 changeCount 变化**合并成一次实际读取/存储**，避免频繁写库。
- 字符串证据：`pasteboard.monitoring`、`Sync timer fired`、`storeFailureReportDates`。

### 2.2 触发入口
- `handlePollTimer:`（`0x1003a2724`）— 轮询触发
- `handleSyncTimer:`（`0x1003a2764`）— 0.3s 防抖定时器触发，内部调 `FUN_1003a28a8`

---

## 3. 同步层：PasteboardHistoryManager.sync(from:)

`FUN_1003a28a8`（`0x1003a28a8`）反编译还原的完整步骤：

1. **获取前台应用**：`NSWorkspace.shared.frontmostApplication.bundleIdentifier` 作为「来源应用」；无前台应用记 `unknown`。日志：`Starting Pasteboard sync from <app>`。
2. **读 changeCount**：`pasteboard.changeCount` 存入对象 `+0x30`（作为版本号/防重入）。
3. **macOS 15.4+ 特殊分支**：`_stdlib_isOSVersionAtLeast(15,4,0)` 且 pasteboard 状态 ≠ 正常时，发通知 `pasteboardHistoryManagerDidChangeStatus` 后返回（系统权限/访问受限处理）。
4. **读 items**：`pasteboard.pasteboardItems` → `[NSPasteboardItem]`。空 → `No items in system pasteboard`；读取失败 → `Error reading system pasteboard items`。
5. **遍历每个 NSPasteboardItem**：
   - 汇总该 item 的所有可用 type，日志 `Retrieve: types: <类型, 逗号分隔>`。
   - **去重**：用 `_stringCompareWithSmolCheck` 与已处理类型列表比较，跳过已存在的类型（`Skipping pasteboard type ...`，常量 `0x100e17040`）。
   - 写回剪切板前通知 delegate（`pasteboardHistoryManagerDidRequestAccess`，weak delegate 判空）。
   - 对每个 type 调 `dataForType:`（`FUN_100c41600`）取 `NSData` → `Foundation::Data`。
   - **单次累计大小保护**：累计 `local_138`，超过阈值 `0x40000001`（约 **1GB**）时报错 `Error creating item for pasteboard content`、`Ignored pasteboard type` 等，跳过超大内容。
   - 否则把 type 追加到 `PasteboardItem.types`，把 Data 写入 `PasteboardItem.dataByType`（`FUN_10033fa8c`）。
6. **合并 items**：所有处理完的 `PasteboardItem` 通过 Swift Array 扩容追加到 `pasteboardItems` 缓存（对象 `+0x28`）。
7. **落库**：`FUN_1003a5218(self)` 保存上下文，将新 items 写入 CoreData。
8. **收尾**：日志 `Pasteboard sync completed, sending delegate callback`、`All done`，发 delegate 回调。

---

## 4. 去重与 checksum

- **运行时去重**：`pasteboard.changeCount` 作为版本号（同一次轮询变化只处理一次）；逐类型字符串比较 `_stringCompareWithSmolCheck` 跳过已存在类型。
- **持久化去重**（SQLite schema 实证）：`ItemEntity` 的 `ZCHECKSUM`（普通索引）+ `ZIDENTIFIER`（唯一索引）保证内容唯一。写入前按 checksum 查询决定 insert/update。
- **setChecksum:** 存在（`objc_stub::setChecksum:`），说明 checksum 在 item 入 Store 前计算并写入字段。

---

## 5. 存储层（CoreData schema，实证）

- **栈**：CoreData(SQLite) + CloudKit，启用 `NSPersistentHistoryTracking`。
- **元数据与内容分离**：
  - `ZITEMENTITY`（Item）轻量列：`ZTITLE`、`ZCHECKSUM`、`ZRAWTYPE`、`ZTIMESTAMP`、`ZDISPLAYORDERINPINBOARD`、来源应用/分组外键、`ZRAWPREVIEW`（预览 blob 内联）。
  - 完整 pasteboard 内容存独立表 `ZITEMDATAENTITY`（`ZRAWPASTEBOARDITEMS` BLOB）。列表加载**不触碰**该表。
- **分组/置顶**：`ZLIST`、`ZLISTMETADATAENTITY`、`ZDISPLAYORDERINPINBOARD`。
- **来源应用**：`ZAPPLICATIONENTITY`（`ZBUNDLEIDENTIFIER` 唯一 + `ZRAWICON` 图标 + `ZRAWCOLOR` 主题色）。

---

## 6. 加载层（动态机制，反编译实证）

- **排序**：`ItemEntity.defaultSortDescriptors`（`0x100345e8c`）→ 构造 2 个 `NSSortDescriptor`：
  - 描述符 1：`NSSortDescriptor(key: "timestamp", ascending: NO)` — **时间戳降序，最新在前**（历史列表核心排序）。
  - 描述符 2：另一 `NSSortDescriptor`（keyPath 间接引用，静态不可读）。
- **差异更新**：`PasteCore.DifferenceFetchedResultsDelegate` 的 `controller:didChangeContentWithDifference:`（`0x100377f98`）→ 把 FRC 的 `NSOrderedCollectionDifference` 桥接为 `Swift::CollectionDifference`（`__unconditionallyBridgeFromObjectiveC`）→ 应用到 **NSDiffableDataSourceSnapshot** 增量刷新。
- **数据流**：`itemsSubject`（`CurrentValueSubject<[PasteCore.ItemEntity]>`）→ `itemsPublisher`（`AnyPublisher<[ItemEntity]>`）。
- **分页**：`setFetchLimit:` / `setFetchAttributes:` + FRC `fetchBatchSize`。

---

## 7. 搜索层

- 实体 `SearchableItemEntity`（`0x100c86e10`）+ `PasteSearch` 模块（`SpotlightIndex`/`SpotlightIndexer`/`SpotlightIndexDelegate`）→ **用 CoreSpotlight / 独立可搜索实体对内容建索引**，搜索不扫原始大字段。
- 局部/补充场景谓词：`%K != nil AND %K CONTAINS %@`。

---

## 8. 跨设备同步（CloudKit）

- `NSPersistentHistoryTracking` + `objc_stub::currentPersistentHistoryTokenFromStores:`（`0x100c41440`）读历史 token。
- `PersistentHistoryObserver` 监听存储变更后增量刷新。
- `CKSyncEngine`（CloudKit 框架）`$fetchChanges` / `FetchedRecordZoneChanges` 拉取远端变更。

---

## 9. 粘贴层

- `PasteCore.PasteboardWriter`：`writableTypesForPasteboard:` / `pasteboardPropertyListForType:` — 把 `ItemEntity` 还原为 `[PasteboardItem]` 写入 `NSPasteboard`。
- `PasteCore.PasteboardItem`：`initWithCoder:` / `encodeWithCoder:` / `supportsSecureCoding` — 可（安全）序列化，支持存储与传输。
- 系统写入原语：`NSPasteboard::clearContents` / `setString:forType:` / `writeObjects:` / `readObjectsForClasses:options:`。

---

## 10. 关键常量汇总

| 常量 | 值 | 含义 |
|---|---|---|
| 防抖间隔 | `0x3fd3333333333333` | 0.3s 防抖定时器，合并连续复制 |
| 单次内容阈值 | `0x40000001` | ≈1GB，超限跳过超大 pasteboard 内容 |
| 排序 | `NSSortDescriptor("timestamp", descending)` | 历史列表最新在前 |
| 系统版本分支 | `_stdlib_isOSVersionAtLeast(15,4,0)` | macOS 15.4+ pasteboard 权限分支 |
| 同步开关字符串 | `pasteboard.monitoring` | 轮询/监控标识 |

---

## 11. 对 Clipaste 的启示（要点）

1. **捕获**：建议对齐「轮询 `changeCount` + 0.3s 防抖定时器」——比每次变化立即写库更能合并高频复制、减少写放大。Clipaste 应确认当前捕获方式是否有防抖合并。
2. **来源应用**：用 `NSWorkspace.shared.frontmostApplication.bundleIdentifier` 记录来源应用（Clipaste 已有 `appLocalizedName`，可补 bundleID）。
3. **内容大小保护**：引入 ~1GB 单条上限，超大内容跳过并告警，避免极端数据拖垮存储/加载。
4. **元数据/内容分离**：轻量列 + 独立内容表（Clipaste 已用 `@Attribute(.externalStorage)` 等效）。
5. **去重唯一性**：`ZCHECKSUM` 索引 + `ZIDENTIFIER` 唯一（对应 Clipaste P0-1 `contentHash` 唯一约束）。
6. **搜索索引**：独立可搜索实体/CoreSpotlight（对应 Clipaste P0-2 FTS5）。
7. **加载**：FRC/Diffable 差异更新 + `timestamp` 降序（Clipaste 可评估差异式列表更新替代全量刷新）。

---

## 12. 参考（反编译来源）

- 目标：`/tmp/paste_arm64`（Paste arm64 slice，SHA256 `40659898a28854154e3bf0db0d9b29dffa539a047aeed90ac43be68b27be46e9`）
- 工具：rea + Ghidra 12.1.4（`REA_GHIDRA_STARTUP_TIMEOUT_MS` 突破默认 330s）
- 关键函数地址：
  - `_TtC9PasteCore10Pasteboard::handlePollTimer:` `0x1003a2724`
  - `_TtC9PasteCore10Pasteboard::handleSyncTimer:` `0x1003a2764`
  - `FUN_1003a3a78`（poll 核心：changeCount + 0.3s 防抖）`0x1003a3a78`
  - `FUN_1003a28a8`（sync 核心：PasteboardHistoryManager.sync）`0x1003a28a8`
  - `_TtC9PasteCore10ItemEntity::defaultSortDescriptors` `0x100345e8c`
  - `_TtC9PasteCore32DifferenceFetchedResultsDelegate::controller:didChangeContentWithDifference:` `0x100377f98`
  - `objc_stub::currentPersistentHistoryTokenFromStores:` `0x100c41440`