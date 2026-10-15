# Clipaste 剪切板历史「加载」逻辑完善文档（P0）

> 本文档由 AI 基于对 **Paste.app (v7.0.2, `com.wiheads.paste`)** 的逆向分析 + **Clipaste 源码链路** 的对比，给出首个实施批次（**P0**）的改进方案。
> 目标读者：实现本批次改造的工程师。请按「方案 → 涉及文件 → 验收标准」逐项落地。

---

## 0. 摘要（给实现者的 TL;DR）

| 编号 | 改进点 | 严重度 | 一句话方案 |
| --- | --- | --- | --- |
| P0-1 | `contentHash` 无数据库唯一约束，去重仅靠应用层 | 高 | 给 `ClipboardRecord.contentHash` 加 `@Attribute(.unique)`，迁移前先清理重复 |
| P0-2 | 搜索对 `plainText`/`appLocalizedName` 全表扫描、无索引 | 高 | 引入 SQLite **FTS5** 全文索引服务，搜索走 FTS5 `MATCH` |

两个 P0 互相独立，可分别落地。

---

## 1. 背景：Paste 的「历史加载」架构（实证）

通过 rea 静态分析 + 读取 Paste 的 CoreData SQLite（`~/Library/Containers/com.wiheads.paste/Data/Library/Application Support/Paste/db.sqlite`）schema + 二进制字符串提取，确认 Paste 的存储与加载设计：

### 1.1 存储层（CoreData + CloudKit）
- 栈：**CoreData(SQLite) + CloudKit**，启用 `NSPersistentHistoryTracking`（跨设备增量同步）。
- **元数据与内容分离**（关键）：
  - `ZITEMENTITY`（Item）只存轻量列：`ZTITLE`、`ZCHECKSUM`、`ZRAWTYPE`、`ZTIMESTAMP`、`ZDISPLAYORDERINPINBOARD`、来源应用/分组外键、`ZRAWPREVIEW`（预览 blob 内联）。
  - 完整 pasteboard 内容存独立表 `ZITEMDATAENTITY`（`ZRAWPASTEBOARDITEMS` BLOB）。列表加载**不触碰**该表。
- **去重**：`ZCHECKSUM` 普通索引 + `ZIDENTIFIER` 唯一索引。
- **分组/置顶**：`ZLIST`（分组）、`ZLISTMETADATAENTITY`（列表元数据）、`ZDISPLAYORDERINPINBOARD`（置顶顺序）。
- **来源应用**：`ZAPPLICATIONENTITY` 独立表（`ZBUNDLEIDENTIFIER` 唯一 + `ZRAWICON` 图标 + `ZRAWCOLOR` 主题色）。

### 1.2 加载层（实证字符串）
- **列表驱动**：使用 `NSFetchedResultsController`（`initWithFetchRequest:managedObjectContext:sectionNameKeyPath:cacheName:`），增量刷新 + 分区 + 自动监听上下文变更。
- **分批分页**：`setFetchBatchSize:`、`setFetchLimit:`、`setFetchOffset:`、`setMaxBatchSize:`，并用 `countForFetchRequest:` 判断是否还有更多。
- **增量更新**：`PasteCore.PersistentHistoryObserver`（配合 `NSPersistentHistoryToken`）监听存储变更后增量刷新。
- **搜索**：模块 `PasteSearch` 提供 `SpotlightIndex`、`SpotlightIndexer`、`SpotlightIndexDelegate` + 实体 `SearchableItemEntity` + `CDSearchIndexerDataSource` —— **用 CoreSpotlight / 独立可搜索实体对内容建索引**，避免列表/搜索时全表扫原始内容。
- **查询谓词**：`%K != nil AND %K CONTAINS %@`（局部/补充场景用 CONTAINS）。

> **对 Clipaste 的启示**：Paste 通过「轻量列 + 独立内容表 + 可搜索实体」让列表秒开、搜索不扫大字段。Clipaste 的 `@Attribute(.externalStorage)` 分离已等效于 Paste 的「轻量列/内容表分离」，但**搜索与去重**两项仍落后（见下）。

### 1.3 加载层动态机制（Ghidra 反编译实证）

通过 rea + Ghidra 12.1.4 反编译 Paste 主程序（arm64 slice `/tmp/paste_arm64`）的 Swift 符号，补充加载历史的**动态机制**：

- **排序（核心）**：`PasteCore.ItemEntity.defaultSortDescriptors`（`0x100345e8c`）反编译为构造 2 个 `NSSortDescriptor`：
  - 描述符 1：`NSSortDescriptor(key: "timestamp", ascending: NO)` —— **按时间戳降序，最新记录在前**（历史列表核心排序，keyPath 由内联立即数 `movk` 拼出，非数据段字符串）。
  - 描述符 2：另一 `NSSortDescriptor`（keyPath 经间接指针 `DAT_101029d58` 引用，静态不可读）。
- **差异更新**：`PasteCore.DifferenceFetchedResultsDelegate`（`_TtC9PasteCore32DifferenceFetchedResultsDelegate`）实现 `controller:didChangeContentWithDifference:`（`0x100377f98`）——把 FRC 的 `NSOrderedCollectionDifference` 用 `Swift::CollectionDifference.__unconditionallyBridgeFromObjectiveC()` 桥接为 Swift 差异，应用到 **NSDiffableDataSourceSnapshot** 增量刷新（`v32@0:8@"NSFetchedResultsController"16@"NSOrderedCollectionDifference"24`）。
- **数据流**：`itemsSubject`（Combine `CurrentValueSubject<[PasteCore.ItemEntity]>`，`0x1011a55b3`）→ `itemsPublisher`（`AnyPublisher<[PasteCore.ItemEntity]>`，`0x1011a574a`），历史列表由 Combine publisher 驱动。
- **分页**：`setFetchLimit:` / `setFetchAttributes:`（objc_stub），配合 FRC `fetchBatchSize` 分批。
- **CloudKit 同步**：`objc_stub::currentPersistentHistoryTokenFromStores:`（`0x100c41440`）读取 `NSPersistentHistoryToken`，配合 `PersistentHistoryObserver` 做跨设备增量同步；`CKSyncEngine`（CloudKit 框架）拉取变更。

> 反编译结论印证第 1.1/1.2 节：Paste 用「FRC + `timestamp` 降序 + 差异快照 + Combine publisher」加载历史，列表只取轻量列、分批、增量。

---

## 2. Clipaste 现状诊断

### 2.1 已做得好的（无需改动）
- 重量级字段用 `@Attribute(.externalStorage)` 分离：`fullTextData/previewImageData/imageData/rtfData/richTextArchiveData/appIconData/linkIconData`（`clipaste/Models/ClipboardRecord.swift:14,17,18,26,31,33,34`）。
- 列表快照 `ClipboardRecordSnapshot.makeFromRecord` 明确「不触碰任何 externalStorage getter」（`clipaste/Managers/ClipboardStorageModels.swift:31-81`），避免 EXC_BAD_ACCESS 与拉取大对象。
- 图片/预览用 `.task(id:)` 异步懒加载 + `ClipboardImagePipeline` NSCache（`clipaste/Views/ClipboardImageViews.swift:32-37`、`clipaste/Managers/ClipboardImagePipeline.swift:41-73`）。
- 读路径经 `StorageManager.detachedRead` 搬离主线程（`clipaste/Managers/StorageManager.swift:36-43`）。
- 打开面板即后台分页加载到内存上限 2000 条（`clipaste/ViewModels/ClipboardViewModel+HistoryLoading.swift:20-77`）。

### 2.2 P0 短板
1. **搜索全表扫描、无索引**：
   - `clipaste/Managers/ClipboardSearcher.swift:15-18` 谓词 `record.plainText?.localizedStandardContains(query)` / `record.appLocalizedName?.localizedStandardContains(query)`。
   - `localizedStandardContains` 在 SQLite 层无法利用 B-tree 索引做子串匹配，对全表逐行扫描；历史量达到数万条时搜索明显变慢。
   - 内存过滤（`clipaste/Services/ClipboardFilterEngine.swift:18-50`）只在已载入的 ≤2000 条上工作；超过上限后回退 SQL 直查（`clipaste/ViewModels/ClipboardViewModel+Filtering.swift:65,92-150`），即命中前述全表扫描路径。
2. **`contentHash` 无唯一约束**：
   - `clipaste/Models/ClipboardRecord.swift:8` 的 `contentHash` 无 `@Attribute(.unique)`。
   - 去重完全依赖应用层 `upsert`（`clipaste/Managers/ClipboardStoreActor+RecordCommands.swift:23-109`）+ 定期 `repairDuplicateRecords`（`clipaste/Managers/ClipboardStoreActor+DuplicateMaintenance.swift:5-76`）兜底，存在瞬时重复窗口与竞态风险。

---

## 3. P0-1：为 `contentHash` 建立数据库唯一约束

### 3.1 问题
- 无唯一索引 → 并发写入 / 异常路径可能产生多条 `contentHash` 相同的记录，去重依赖事后修复，正确性有窗口。
- 现有 `upsert` 每次都要先 `fetch(contentHash == hash)` 再决定 insert/update，重复键时还须合并删除多余副本（`RecordCommands.swift:81-84`），成本高。

### 3.2 方案
1. **给字段加唯一约束**：
   ```swift
   // clipaste/Models/ClipboardRecord.swift
   @Attribute(.unique) var contentHash: String = ""
   ```
   SwiftData 会为 `contentHash` 在底层 SQLite 建立唯一索引。
2. **迁移前置清理**：唯一索引要求存量数据无重复，否则建索引失败。启动引导已调用 `repairDuplicateRecordsIfNeeded`（`clipaste/Managers/ClipboardRuntimeStore+Bootstrap.swift:24`）。需**确认**该清理发生在首次带唯一索引的迁移之前，并覆盖存量重复（含全表分页扫描的 `repairDuplicateRecords`）。若索引为运行时新建，应先在旧 schema 上跑一次去重再启用。
3. **`upsert` 语义调整（可选优化）**：保留「先查后更」逻辑（更稳妥，避免唯一冲突 exception）。由于唯一约束兜底，可去掉「合并删除多余副本」的循环（`RecordCommands.swift:81-84`）——同一 hash 至多一条；但为兼容历史数据，可保留防御性合并。**建议保留防御逻辑**，仅以唯一索引作最后防线。
4. **冲突兜底**：若未来出现 `NSConstraintConflict`，捕获后回退为「按 hash 查询→更新」并记录日志（`RecordCommands.swift:121-123` 已有 `catch`）。

### 3.3 涉及文件
- `clipaste/Models/ClipboardRecord.swift`（加 `@Attribute(.unique)`）
- `clipaste/Managers/ClipboardRuntimeStore+Bootstrap.swift`（确认/保证迁移前去重）
- `clipaste/Managers/ClipboardStoreActor+DuplicateMaintenance.swift`（如需强化迁移前去重）
- 测试：`scripts/` 下新增或扩展现有去重相关测试（参考 `scripts/ClipboardStoreActor+DuplicateMaintenance` 相关测试文件）

### 3.4 验收标准
1. 数据库 schema 中存在 `contentHash` 的唯一索引（可通过 sqlite 检查主 store 的索引确认）。
2. 连续两次以相同 `contentHash` 写入：第二次更新时间戳并置顶，数据库中该 hash 仅 1 条记录。
3. 带唯一索引后冷启动/热迁移不抛异常，历史重复记录在首次启动被清理。
4. 并发写入相同 hash 不产生重复行。

---

## 4. P0-2：搜索改用 SQLite FTS5 全文索引

### 4.1 问题
- 搜索对 `plainText`/`appLocalizedName` 用 `localizedStandardContains` 全表扫描，无索引；历史量大时慢。
- 现有「内存过滤 + SQL 直查补充」双路径，补充路径命中全表扫描（`ClipboardSearcher.swift:15-18`）。

### 4.2 目标
- 用**自包含、无第三方依赖**的方式（macOS 自带 `sqlite3` / SQLite FTS5）为历史内容建立全文索引，搜索走 FTS5 `MATCH` 返回命中的 `id`，再按需回源取记录。这等价于 Paste 用「可搜索实体 + 索引」避免扫大字段的思路。

### 4.3 架构设计
新增一个 **FTS 索引服务**（actor，独立于 SwiftData store），维护一个独立 SQLite 库文件（不侵入 SwiftData 管理的 store，避免手动改 SwiftData schema 的风险）。

**新增文件**：`clipaste/Services/ClipboardSearchIndexer.swift`

职责：
- 维护独立 SQLite 库（路径建议：与主 store 同目录，如 `Application Support/Clipaste/search-fts.sqlite`）。
- 建表：
  ```sql
  CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_fts USING fts5(
    id UNINDEXED,
    plainText,
    appName,
    contentHash UNINDEXED,
    typeRawValue UNINDEXED,
    timestamp UNINDEXED,
    tokenize = 'unicode61'
  );
  ```
- **同步时机**（关键）：
  - 写入/更新：在 `ClipboardStoreActor.upsert` 成功 `save()` 后，同步 upsert FTS 行（按 `id` 或 `contentHash`）。文本取内联 `plainText`（`ClipboardRecord` 的普通列，不触碰 externalStorage `fullTextData`；超长文本已被截断存于 `plainText`，见 `ClipboardRecord.swift:10-16`）。
  - 删除：`ClipboardStoreActor.delete` / `cleanUpExpiredRecords` / `deleteUnpinnedRecords` 后同步删除 FTS 行。
  - 同步应放在 `@ModelActor` 内、同一保存事务上下文之后，用独立 actor 执行避免阻塞主线程。
- **搜索**：`ClipboardSearcher` 增加「走 FTS」分支：`query` 非空时先 `SELECT id, rank FROM clipboard_fts WHERE clipboard_fts MATCH ? ORDER BY rank, timestamp DESC LIMIT n`，得到命中 id 集合，再按 id 回源（可按时间排序）组装 `ClipboardItem`。
- **tokenize**：默认 `unicode61`（支持中文分词为单字，满足子串近似搜索）。如需英文词干可评估 `porter`，但对中文默认 unicode61 即可。

### 4.4 集成点与改动文件
- 新增 `clipaste/Services/ClipboardSearchIndexer.swift`（FTS 服务，`import SQLite3`）。
- `clipaste/Managers/ClipboardStoreActor+RecordCommands.swift`：
  - `upsert` 保存后调用 indexer upsert FTS 行（`:108-120` 附近）。
  - `delete`、`cleanUpExpiredRecords`、`deleteUnpinnedRecords` 保存后调用 indexer 删除 FTS 行（`:146-189`）。
- `clipaste/Managers/ClipboardSearcher.swift`：
  - `searchAndMap`：query 非空时走 FTS 命中 id 集合回源；query 空时保持现有 `timestamp` 逆序分页。
  - 保证 FTS 查询也支持 `fetchLimit/offset`，兼容现有分页调用方（`StorageManager+HistoryQueries.swift:18-29`）。
- `clipaste/Managers/ClipboardRuntimeStore+Bootstrap.swift`：启动时初始化 indexer、**全量重建**（从主 store 分批读取 `plainText` 建 FTS，防止早期版本无索引）。
- 依赖：macOS 自带 `SQLite3.framework`，无需新增 SPM 依赖（`import SQLite3`）。

### 4.5 并发与一致性
- `ClipboardSearchIndexer` 用 `actor` 隔离，写操作在后台队列；搜索是只读。
- 删除/过期/清空要与 FTS 删除一致（同一 `@ModelActor` 事务后同步）。
- 全量重建建议在 `.background` QoS 分批执行，避免启动卡顿；重建期间搜索可回退旧路径（先切新路径再重建亦可，视实现取舍）。

### 4.6 验收标准
1. 插入一条含唯一词（如「齐天大圣」）的文本后，搜索「齐天大圣」能命中该条。
2. 删除该条后，搜索不再命中。
3. 更新该条文本后，索引反映新文本（旧词不命中、新词命中）。
4. 历史库在 1 万+ 条规模下，搜索响应时间较改造前（`localizedStandardContains` 全表扫描）有明显下降（可测 p95）。
5. 中文与英文混合内容搜索正常；搜索分页（`fetchLimit/offset`）行为与现有 `searchAndMap` 兼容。
6. 全量重建后索引与主 store 一致（抽样核对条数）。
7. 新增单元测试覆盖：插入/更新/删除/重建/分页（参考 `scripts/ClipboardSearchSupplementPolicyTests.swift` 等现有搜索相关测试）。

### 4.7 可选最小改动（若 FTS 短期不可行）
若希望先低成本缓解，可：
- 为排序字段 `timestamp` 建立索引（SwiftData `#Index` 或利用现有），仅改善排序分页，不解决子串搜索。
- 为 `databaseSearchSupplement` 增加更小步长分页与查询超时护栏，减少长查询卡顿。
> 推荐仍以 FTS5 为准，以上仅为过渡。

---

## 5. 风险与注意事项
- **P0-1 唯一索引迁移**：先清理重复再启用，否则建索引失败；迁移需在测试环境用带重复的库验证。
- **P0-2 FTS 与 SwiftData store 分离**：不要直接修改 SwiftData 管理的主 store 结构；FTS 用独立库，靠 `id`/`contentHash` 关联，避免 SwiftData 版本升级破坏。
- **超长文本**：FTS 只索引内联 `plainText`（已是截断前缀），不索引 `fullTextData`，避免大字段入索引。
- **并发**：写入与搜索都要离开主线程；`ClipboardSearchIndexer` 用 actor。
- **CloudKit 同步**：FTS 索引为本地加速用，不参与 CloudKit 同步（内容仍以 SwiftData 记录为准）；同步新增记录后需增量补索引（可在 PersistentHistory/变更通知处触发）。

---

## 6. 参考（Paste 实证来源）
- Paste 二进制：`/Applications/Paste.app/Contents/MacOS/Paste`（arm64，SHA256 `6b0925d59a...`）
- 数据库 schema：`~/Library/Containers/com.wiheads.paste/Data/Library/Application Support/Paste/db.sqlite`
- 关键证据：`ZITEMENTITY`/`ZITEMDATAENTITY` 分离、`ZCHECKSUM`+`ZIDENTIFIER` 索引、`ZDISPLAYORDERINPINBOARD`、`SearchableItemEntity`+`PasteSearch.SpotlightIndexer`（CoreSpotlight）、`NSFetchedResultsController`+`setFetchBatchSize/SetFetchLimit/SetFetchOffset/MaxBatchSize`+`countForFetchRequest`、`PersistentHistoryObserver`、谓词 `%K CONTAINS %@`。
- Ghidra 反编译（rea + Ghidra 12.1.4，arm64 slice `/tmp/paste_arm64`）：`ItemEntity.defaultSortDescriptors`（`NSSortDescriptor(key:"timestamp", ascending:NO)`）、`DifferenceFetchedResultsDelegate::controller:didChangeContentWithDifference:`（`NSOrderedCollectionDifference`→`Swift::CollectionDifference`）、`itemsSubject`/`itemsPublisher`（Combine `CurrentValueSubject<[ItemEntity]>`）、`currentPersistentHistoryTokenFromStores:`。

---

## 7. 内存占用对齐（Paste 为何省内存）

### 7.1 Paste 内存占用少的归因（历史加载算法）

1. **轻量列与内容分离**：列表只拉 `ZITEMENTITY` 轻量列（title/checksum/timestamp/来源/分组），完整 pasteboard 内容在 `ZITEMDATAENTITY`（BLOB），**列表加载从不触碰** → 大内容不进内存。
2. **FRC 按需分批窗口**：`NSFetchedResultsController` + `fetchBatchSize`，SQLite 层分批，**内存只驻留可见窗口**，随滚动按需取/释放，而非全量常驻。
3. **独立搜索索引**：`SearchableItemEntity` 建索引搜索，不把原始大字段载入内存做子串匹配。

### 7.2 Clipaste 当前差距

- Clipaste 已在「轻量列/内容分离」对齐（`@Attribute(.externalStorage)` + 快照不触碰 externalStorage getter，见 §2.1），大内容同样不进内存。
- **但加载窗口策略不同**：
  - Clipaste：首屏 80（`initialVisibleItemBatchSize`）→ 后台每页 160（`backgroundPageBatchSize`）→ **内存上限 2000 条常驻**（`backgroundLoadMaxItems`，`clipaste/ViewModels/ClipboardViewModel.swift:37-41`）。
  - Paste：FRC 只驻留可见窗口（几十条级），滚动按需取。
- **差距**：Clipaste 会把最多 2000 条 `[ClipboardItem]` 快照**常驻内存**；虽每条是轻量对象（不含大内容），但对象头 + title/元数据 × 2000 条仍显著高于 Paste 的可见窗口驻留量。历史量越大差距越明显。

### 7.3 建议（后续批次，非 P0）

- 引入**分页窗口 + 远端释放**（虚拟化列表）：只保留「可见窗口 + 上下预取若干页」在内存，滚出窗口的记录从 `[ClipboardItem]` 移除、需要时按 `id` 回源重建，等价于 FRC 的按需窗口语义。
- 明确「常驻上限」从「条数」升级为「**内存字节预算**」（如按估算快照大小设定上限），并在超预算时释放最远记录。
- 排序/范围查询已走 SQLite（`detachedRead` + `fetchItemsPage`），只需在上层把「已拉入的数组」改为「窗口缓存」，即可在不改 SQL 层的前提下落地。
- 若长期需要大窗口，评估引入 FRC/DiffableDataSource 式按需加载（对齐 Paste §6），替换当前「后台全量拉满」策略。