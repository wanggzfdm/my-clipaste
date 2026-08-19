# Clipaste 常驻内存优化设计

**日期：** 2026-08-18  
**状态：** 已批准（方案 A）  
**目标：** 将后台空闲物理内存从约 0.9–1.2GB 压到 **&lt; 300MB**（争取 &lt; 200MB）

---

## 1. 问题与证据

对运行中的 `Clipaste 2.1.6` 采样（本机）：

| 指标 | 观测值 |
|------|--------|
| Physical footprint | ~0.8–0.94GB |
| Peak | 1.2GB |
| 堆主因 | `_PFExternalReferenceData._bytesPtrForStore` ≈ 332MB / ~8900 块 |
| 次因 | `MALLOC_SMALL` 碎片、Vision/Espresso、多份 `[ClipboardItem]` |
| 磁盘（非本次主目标） | `clipboard-local.store` ~291MB + `_EXTERNAL_DATA` ~617MB |

### 根因

列表/快照映射通过访问 externalStorage 属性判断“是否有数据”：

```swift
hasPreviewImage: record.previewImageData != nil
hasImageData: record.imageData != nil
hasLinkIcon: record.linkIconData != nil
hasRTF: record.rtfData != nil || record.richTextArchiveData != nil
```

在 SwiftData/CoreData 中，对 `@Attribute(.externalStorage)` 做 `!= nil` 会 **fault-in 整块 blob**，并常驻 `ModelContext`，导致空闲态仍占用数百 MB。

### 次要问题

- 关面板 `releaseTransientResourcesAfterPanelClose()` 只裁剪 `items`，不清：
  - `ClipboardImagePipeline`（NSCache 上限 64MB）
  - `ListRenderEngine`（AttributedString 缓存）
  - `AppIconManager`（NSCache 上限 20MB）
- 列表 fetch 后未系统性地 `rollback`/释放已注册对象（export 路径已有分批 + rollback 先例）。

---

## 2. 目标与非目标

### 目标

1. 列表/分页/warm-cache 路径 **永不读取** external blob 本体，只读轻量标量/Bool。
2. 面板关闭后主动释放瞬时图像与排版缓存。
3. fetch 映射后降低 `ModelContext` 常驻对象图。
4. 验收：
   - 冷启动空闲约 5 分钟：Physical footprint **&lt; 300MB**（争取 &lt; 200MB）
   - 打开面板滚动图片后关闭约 30s：回到接近空闲水位
   - `heap`：列表加载后 `_PFExternalReferenceData._bytesPtrForStore` 不再出现百 MB 级堆积

### 非目标（本轮不做）

- 磁盘历史压缩、外存 GC、变更历史保留策略
- 列表架构改为纯 ID store
- 重写 CloudKit 同步模型

---

## 3. 方案总览（已选 A）

**存在性标志 + 回填迁移 + 空闲回收。**

```text
写入 blob ──► 同步写 presence Bool
列表 fetch ──► 只读 Bool/标量 ──► 可选 rollback 减压
按需预览 ──► 仍读 blob（缩略图/粘贴/OCR）
关面板   ──► invalidate 图像/排版/图标缓存 + 保留 warm 首屏
```

---

## 4. 数据模型

### 4.1 `ClipboardRecord` 新增字段

全部为轻量 `Bool`，默认 `false`，**不是** externalStorage：

| 字段 | 含义 |
|------|------|
| `hasPreviewImageData` | `previewImageData` 非空 |
| `hasOriginalImageData` | `imageData` 非空 |
| `hasLinkIconData` | `linkIconData` 非空 |
| `hasRTFData` | `rtfData` 非空 |
| `hasRichTextArchiveData` | `richTextArchiveData` 非空 |

> 命名避免与 DTO 的 `hasImageData`/`hasLinkIcon` 混淆：Record 用 `has*Data` / `hasOriginalImageData` 后缀表达“库内 blob 存在”。

### 4.2 写入路径不变量

凡赋值 blob，必须同步更新对应 Bool：

- `previewImageData = x` → `hasPreviewImageData = (x?.isEmpty == false)`
- `imageData = x` → `hasOriginalImageData = ...`
- `linkIconData = x` → `hasLinkIconData = ...`
- `rtfData = x` → `hasRTFData = ...`
- `richTextArchiveData = x` → `hasRichTextArchiveData = ...`
- 清空（`nil`）时对应 Bool = `false`

覆盖点至少包括：

- `ClipboardStoreActor` 插入/更新/合并/导入
- OCR / link metadata / RTF 回填
- Cloud/local 合并、去重合并

### 4.3 列表读取路径

`ClipboardRecordSnapshot` 与 `makeClipboardItem`：

- `hasPreviewImage` ← `record.hasPreviewImageData`
- `hasImageData` ← `record.hasOriginalImageData`
- `hasLinkIcon` ← `record.hasLinkIconData`
- `hasRTF` ← `record.hasRTFData || record.hasRichTextArchiveData`

**禁止**在列表/snapshot 路径访问 `*Data` external 属性（含 `!= nil`、`== nil`、可选绑定）。

按需 API（`loadPreviewImageData` / `loadImageData` / `loadRTFData` / `loadLinkIconData`）保持现有行为。

### 4.4 回填迁移

- 版本键：`UserDefaults` 如 `clipboard_external_presence_backfill_v1`
- 分批（建议 32–64 条）fetch `ClipboardRecord`
- 对每条：若 Bool 与 blob 实际不一致则修正（仅回填阶段允许读 blob）
- 每批 `save` 后 `rollback`（或等价清空已注册对象），防止迁移本身堆内存
- 可在 `ClipboardRuntimeStore` 激活 runtime 后后台执行；UI 不阻塞
- 幂等：已完成版本跳过

---

## 5. 空闲回收

### 5.1 关面板

扩展 `ClipboardViewModel.releaseTransientResourcesAfterPanelClose()`：

1. 现有：清 `highResImage`、QuickLook 锚点、裁剪 items、收 scope cache
2. 新增：
   - `ClipboardImagePipeline.shared.invalidateAll()`
   - `ListRenderEngine.shared.invalidateAll()`
   - `AppIconManager` 增加 `invalidateAll()` 并调用
3. 保留：`ClipboardHistoryWarmCache` 首屏轻量 DTO（~80）与 `lastScopeSnapshot`

### 5.2 Fetch 后 Context 减压

在 `ClipboardStoreActor` 列表类 fetch（分页 history、warm cache 预热等）映射为 snapshot/DTO **之后**：

- `modelContext.rollback()`（只读路径；无未保存写操作时安全）
- 写路径仍正常 `save`，不在未 save 的写事务中 rollback

与 `exportStore()` 的“分批 + rollback”策略对齐。

### 5.3 内存压力（增强）

- 监听系统 memory pressure（`DispatchSource.makeMemoryPressureSource` 或等价）
- 在 warning/critical 且面板未展示时：执行与关面板相同的缓存清理 + 可选 actor context rollback
- 打开面板时不强制清缩略图（避免闪烁），仅 critical 时可降级

### 5.4 缓存预算

| 缓存 | 打开面板 | 关闭/空闲 |
|------|----------|-----------|
| ImagePipeline | 保持现上限（体验） | 清空 |
| ListRenderEngine | 256 条 FIFO | 清空 |
| AppIconManager | 现上限 | 清空（可再懒加载） |
| WarmCache | 80 条轻量 DTO | 保留 |

---

## 6. 测试计划

### 单元 / 集成

1. **Presence 写入不变量**：插入带图/RTF/link icon 的 record → Bool 为 true；清空 blob → false。
2. **列表映射不访问 blob**：snapshot 构建仅依赖 Bool；可用测试 double / 断言 helper 保证。
3. **回填幂等**：制造 Bool=false 但 blob 非空的旧数据 → 回填后 Bool=true；再跑不改动。
4. **关面板回收**：调用 `endPresentation` 后 pipeline/list/icon cache 为空（测试可注入/可观察 API）。
5. **Fetch rollback**：列表 fetch 后 context 已注册对象数不随多次分页单调暴涨（在可测范围内）。

### 手工 / 性能验收

1. Instruments 或 `vmmap -summary` / `heap`：
   - 冷启动空闲
   - 打开面板滚动含图历史
   - 关闭 30s 后
2. 回归：缩略图、QuickLook、粘贴原图、OCR、富文本预览、链接图标仍正常。

---

## 7. 风险与缓解

| 风险 | 缓解 |
|------|------|
| 旧数据 Bool 未回填导致列表不显示图/RTF 入口 | 启动后台回填；回填完成前可用“保守显示”（可选）或尽快完成回填 |
| rollback 误伤未保存写入 | 仅只读 fetch 路径 rollback；写路径先 save |
| 关面板清缓存导致重开闪白 | warm cache + 首屏 DTO 仍在；缩略图异步回填，可接受短暂占位 |
| SwiftData 轻量迁移加字段失败 | 走现有 ModelContainer 迁移路径；字段均有默认值 |

---

## 8. 实现顺序

1. Record 字段 + 所有写路径同步 Bool  
2. 列表/snapshot 改为读 Bool；删除 `*Data != nil`  
3. 回填迁移  
4. 关面板清缓存 + AppIcon invalidate  
5. 列表 fetch 后 rollback  
6. memory pressure 监听  
7. 测试 + 本机 heap/vmmap 验收  

---

## 9. 成功标准（摘要）

- 空闲 Physical footprint **&lt; 300MB**
- 列表路径零 external blob fault-in（heap 验证）
- 功能回归通过（图/RTF/链接图标/粘贴）
