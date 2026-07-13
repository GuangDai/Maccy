# 架构与根因总览(单一权威参考)

本文档是 Maccy 当前架构、瓶颈、数据安全、内存、路线图完成度的**单一权威参考**,由 ~30 份历史审计文档(2026-06-14 深度审查 / 2026-06-25 模块分析 / 2026-06-27 内存实测 / 2026-06-28 路线图缺口审计)蒸馏而成,并更新到 **2026-07-13 History B2–B5 / C3 / C4 / E5 decorator factory 完成态**。完成度细节见 `docs/audit/2026-06-28-roadmap-bs5-bs8-gap-audit/`,内存实测见 `docs/audit/2026-06-27-memory-floor-and-retention/`。`finding-id` 词汇表见本文末尾。

> 代码标识符保留英文;历史行号仅用于定位旧证据,当前结构以类型名和 2026-07-13 branch HEAD 为准。

---

## 1. 架构总览

### 1.1 单一根因(原始诊断,至今仍是设计的出发点)

> **整条数据管线曾经全部 `@MainActor` 隔离、且只用 SwiftData 的 `container.mainContext`。没有后台 context、没有 actor、没有任何重活被搬离主线程。**

证据(`Storage.swift:5,10`):
```swift
@MainActor class Storage {
  static let shared = Storage()
  var context: ModelContext { container.mainContext }   // 唯一入口,绑死主队列
}
```

BS-1~BS-4 已围绕此根因重构管线(copy 路径已离主线程)。主侧读写仍落在 `mainContext`,但 `History`/projector/mutations 不再直接访问它：所有 IO 经过注入的 `HistoryPersistence`,具体 `ModelContext` 只封装在 `SwiftDataHistoryPersistence`。这解决了 DS-022 测试/耦合问题,**不等于**消除了 mainContext 的 framework retention floor(见 §2、§4)。

### 1.2 两域隔离模型(目标态,部分已落地)

```
┌──────────────── Main(UI 线程)─────────────────┐   ┌──────────────── Background(actor)────────────────┐
│ SwiftUI Views (HistoryListView/ListItemView/      │   │ actor ClipboardIngestor 【BS-2 已接入 live】       │
│  PreviewItemView)——仅绑定 @Observable 状态        │   │  ├─ 读 NSPasteboard(后台)                         │
│                                                    │   │  ├─ 过滤(filterContents)+ 标题(title(for:),       │
│ @Observable History(341 LOC composition facade)    │   │  │   仅必要 AppKit RTF/HTML 解析回 main)             │
│  ├─ HistoryListState(all/items + mutation hook)    │◄──┤  ├─ 去重(SignatureIndex 内存索引,O(h))            │
│  ├─ HistorySearchSession(query/actor/corpus)       │ DTO│  ├─ 单事务写(background context)                  │
│  ├─ HistoryStoreProjector(load/consume/reconcile)  │   │  └─ 发出 StoreEvent + trimmed persistent IDs       │
│  ├─ HistoryItemDecoratorFactory(image resources)   │   │                                                    │
│  └─ HistoryMutations(clear/delete/select/pin)      │   │                                                    │
│       └─ HistoryPersistence → SwiftData adapter    │   │                                                    │
│                                                    │   │ actor ImageProcessor 【BS-3 已接入,E5 显式组合】   │
│ @Observable HistoryItemDecorator(UI 状态)          │   │  ├─ ImageIO 降采样(CGImageSourceCreateThumbnail)   │
│  ├─ thumbnailImage/previewImage(就绪位图)          │   │  └─ 后台解码 + 缩略图/预览(预览封顶 800px)         │
│  └─ applicationImage(NSCache 限界 128)             │   │                                                    │
└────────────────────────────────────────────────────┘   └────────────────────────────────────────────────────┘
                  ▲                                                          │
                  │ AsyncStream<StoreEvent> → History.consume 增量更新       │
                  │ (不全量重排/重装饰)                                       │
```

### 1.3 隔离规则(全流程不变性)

- **跨 actor 载荷必须是 `Sendable`**(DTO/值类型/`Data`/`UUID`)。`@Model HistoryItem` / `HistoryItemContent` **不跨 actor**——跨边界前投影为 DTO(`ItemSnapshotDTO` 等,见 `Maccy/Ingest/Dtos.swift`)。
- **上下文线程归属**:`mainContext` 仅 main；后台 ingestor 的 `@ModelActor` 自建并独占 context。**禁止跨域共用同一 context**。
- **单一真相源**:数据真相是 SwiftData(后台 context 单事务写);主线程 `@Observable` 是其投影。
- **主线程禁做可迁移重活**:`NSImage(data:)` 解码、resize、SwiftData 重 fetch/save、正则、去重比对禁止在 main。AppKit 的 `NSAttributedString(rtf:/html:)` 已被实证为 off-main 会 trap，因此只允许 planner 选中的小型 RTF/HTML 在 main 解析；普通 file/plain/image ingest 不回 main。

### 1.4 已落地的 scaffolding(部分已接线)

| 文件 | 状态 |
|---|---|
| `Maccy/Ingest/Dtos.swift` + `IngestFilter.swift` | ✅ DTO 目录(`ContentDTO`/`ClipboardItemDTO`/`SignatureDTO`/`ItemSnapshotDTO`/`StoreEvent` 等)+ `IngestRequest` 携带的每请求 `IngestPolicy` + 投影函数 `snapshot(of:)` / `contentDTOs(of:)`；`HistoryItemEngine` 只接受 DTO，不再依赖 `@Model`。 |
| `Maccy/Ingest/SignatureIndex.swift` | ✅ 纯值去重索引 `[SignatureDTO: ItemID]`,接入 ingestor(BS-4.2) |
| `Maccy/Ingest/ClipboardIngestor.swift` | ✅ 已接入 live copy 路径(BS-2) |
| `Maccy/ImageProcessing/ImageProcessing.swift` + `ImageProcessor.swift` + `ImageDownsampler.swift` + `ThumbnailCache.swift` | ✅ ImageIO 降采样已接入(BS-3) |
| `HistoryListState` / `HistorySearchSession` / `HistoryStoreProjector` / `HistoryMutations` | ✅ B2–B5 完成:列表变更单 chokepoint、actor 搜索语料/O(1) lookup、单 persistence 投影、fake-backed mutations + value UI effects。E5 首个 DI slice 又将 clipboard/event/current-event/log 服务构造注入；普通 `History` 实例 inert，live globals 仅在 `History.shared` composition factory。`History.swift` 978→346 LOC；full matrix `29210900842`。 |
| `HistoryItemDecoratorFactory` / image composition | ✅ E5 decorator slice:projector 的 load/reconcile/incremental insert 只经 factory 构造；factory 显式拥有 `ImageProcessor` 与 `ApplicationImageCache`。`History.shared` 建一套 live 资源，普通 `History` 使用隔离资源；`CompositionRoot` 将同一 processor 交给 ingest，memory warning 经 attached History 清理同一 icon cache。decorator/cache 不再读取隐藏 `.shared`。 |
| `AppState` runtime boundary | ✅ E5 第二 slice (`ed664b2`):空选择 query copy 构造注入；prewarm 使用当前组合的 History；Settings close observer 弱捕获 owning AppState，不再回写 `AppState.shared`。文件内 shared 使用 8→3，剩余仅 composition/Settings 构建区；full matrix `29211587341`。 |
| Footer action flow | ✅ `7d1d3e2`:FooterItem 携带 closed `FooterAction` value；click/confirmation/keyboard 统一交给 owning AppState 解释，Footer 内 5 个 `AppState.shared` 闭包删除。`f84ffa1` 又覆盖全部 interpreter cases，并把键盘 clear 路由从 title string 收敛为 typed lookup；full matrix `29213836925`。 |
| Navigation → Preview lead flow | ✅ `38ef0c9`:Navigation 在构造时接收单一 current-lead 输出，旧 lead 解码取消仍内聚于 Navigation；AppState 组合该输出到 Preview 的 auto-open/retarget 输入。`NavigationManager` 不再读取 `AppState.shared`，测试也不再借用 global Preview；full matrix `29214579841`。 |
| Slideout runtime boundary | ✅ `c9f2273`:Preview 自持 current lead、弱绑定 panel window，并由 AppState 注入 Popup 高度策略；`SlideoutController` 的 4 个实例级 `AppState.shared` 读取归零，窗口绑定留在 CompositionRoot。 |
| SwiftData history persistence | ✅ `4bcfc47`:adapter 构造注入 caller-owned `ModelContext` 且整体 `@MainActor`；15 个方法内 `Storage.shared` 读取归零。`History` 不再提供隐式 live persistence default，只有 `History.shared` composition factory 选择 `Storage.shared.context`。与 Slideout 联合 full matrix `29215547393`（338 unit，0 failures）。 |
| D1 load 原型 | ✅ run `29176185359` 证明完整历史的 store-sorted 候选仅快约 1%，不具落地价值；窗口化又无内存收益且破坏完整搜索，因此 test-only loader/context 脚手架已删除。 |

---

## 2. 当前管线与瓶颈(逐模块)

> 标注:[已修]=已落地并 CI 绿;[部分]=核心做、收尾/测试缺;[未修]=未触碰;[死代码]=代码存在但零调用方。finding-id 见 §6 词汇表。

### 2.1 Clipboard / Ingest(复制摄取)

| 项 | 状态 | 说明 |
|---|---|---|
| pasteboard poll Timer 同步跑整条管线 | [已修] | `pasteboard-polling-callback-heavy`:Timer 现仅触发 `Task { await ingestor.ingest() }`,重活在 actor(`ClipboardIngestor.swift`) |
| 富文本/标题解析回主线程 | [已修/安全例外] | D2(`a487276`):`Clipboard` 随请求捕获 live policy；纯过滤与 file/plain/image 标题/正文投影都在 ingest actor。仅 `IngestMainActorPlan` 选中的小型 RTF/HTML 因 AppKit 亲和回 main；heavy-text/RTF fixture 与 no-trap 集成测试锁定边界。 |
| 去重全表 fetch | [已修] | `findsimilar-full-refetch`:live 路径改走 `SignatureIndex`(`O(h)` 命中候选数,非 `O(n)`)。legacy `History.findSimilarItem` / `History.add` 已于 B4 删除。 |
| 单复制多次 save | [已修] | `add-does-3-pending-changes-saves`:ingestor 单事务写后台 context |
| copy 风暴无背压 | [已修] | D3(`b754ac6`):`IngestMailbox` 用一个 FIFO drain Task 服务 burst，同一时刻最多一个 ingest；已观察请求全部按序保留，不采用会丢历史的 latest-wins。 |
| `shouldIgnore` 正则全在主线程 | [已修] | D2 后正则规则在 ingest actor 的纯 `filterContents(...richTextPresent:)` 路径执行；只有必要的 AppKit 富文本 presence 解析回 main。 |
| Timer 无 tolerance / 非 common mode | [已修] | E3(`32320cf`):有效 interval 10% tolerance + `.common` run-loop mode。 |

**live 摄取路径**(`ClipboardIngestor` → `History.consume` → `HistoryStoreProjector`):BS-4.4a 已增量(`model(for:)` + 二分插入),G-copy 实测 9.34→0.99ms；trimmed IDs 直接 O(deleted) 清 decorator/search corpus。

### 2.2 History / Storage(加载与状态)

| 项 | 状态 | 说明 |
|---|---|---|
| `load()` 完整 fetch+排序+装饰 | [已决策保留] | D1 用同一批 200 条完整历史 A/B：当前 34.551ms，store-sorted 候选 34.202ms（run `29176185359`），约 1% 属噪声。窗口化 `all` 无内存价值且令搜索漏项，因此不以 UX 换内存/启动指标。 |
| 插入时整表重排 | [已修] | `insert-resorts-whole-array`:增量 consume 用二分插入(`Sorter.BinaryInsertion.index`,`O(log n)`) |
| 容量裁剪多 save 风暴 | [已修] | C4(`04ab27c`):projector 从同一排序结果计算精确未固定 overflow,一次 transaction/save 删除,一次同步 actor index；full matrix `29206774668`。 |
| `withLogging` clear/delete 双 fetchCount | [部分/仅 DEBUG] | 诊断计数仍存在于 `HistoryMutations`,但 `#if DEBUG` 外 release 只执行真实 operation；不再是 release round-trip。 |
| 模型索引缺失 | [未修] | `no-indexes-on-predicate-columns`:`pin`/`lastCopiedAt` 等高频列无索引 |
| legacy `findSimilarItem` / `History.add` | [已删除] | B3 迁移测试后,B4 `c53a183` 删除 writer/sessionLog/adapter；生产与测试都使用 committed store + `StoreEvent` 投影。 |
| History god object / UI 双向耦合 / dual IO | [已修] | B2–B5:四个 cohesive modules + `HistoryUIEffect` value sink；facade 无 `AppState.shared`/direct context,projector/mutations 可用 fake persistence 独立测试。 |
| `Storage.mainContext` 从不 reset/refresh | [未修] | **内存滞留的结构性根因**(见 §4.2);不能直接 `reset()`(见 §4.3 陷阱) |

### 2.3 Search(文本搜索)

> **2026-07-13 结构收敛:** `HistorySearchSession` 现在拥有 query、debounce、generation、in-flight task、actor corpus 与 `[UUID: decorator]` lookup。空 query 直接发布完整列表；非空 query 只用 `SearchActor`。legacy `Search.swift`(217 LOC)及重复测试已删除(`5fd7bf4`,full matrix `29205361439`),DS-010/012/029 关闭。下面 06-28 表格仍是 BS-5 redesign 的历史缺口快照,不应再用其中的 legacy-engine 描述判断当前结构。

> 🔔 **2026-07-06 更新:BS-5 已超本表重设计(全量落地,CI 全绿)** — 见 `docs/audit/2026-07-04-bs5-search-redesign/`(README §九 进度日志 + `decisions.md` ADR-1..10 + glossary)。Track 2 全文搜索(`searchText` 列 + actor 持语料 + 正文扫描 + fuzzy body + mixed 全文 + body 封顶 Defaults + 测量)+ Track 3 预览高亮(SwiftUI AttributedString + `NSTextView` representable)完成。本节下表为 **06-28 缺口审计的历史快照**;其中 **07-F-010 经 T1.1 经验证推翻(Fuse 返 grapheme offset,代码本就正确,`4fa4946` "bug-2 fix" 空夸大)、07-F-013 经 T1.2 `TextLimits` 单源 + clamp-and-log 修复**;`G-search` 闸门经 T2.7 改测 actor 路径(主线程 <16ms ✓,决策 no-index)。下表的 [未修]/[部分] 状态已由重设计纠正。

| 项 | 状态 | 说明 |
|---|---|---|
| 搜索 actor 化(off-main) | [已修] | `actor SearchActor`(`SearchActor.swift:31`)+ `searchGeneration` 生成代 guard + equality guard + destructive 失效(BS-5.6)。设计扎实、正确 |
| **07-F-010 高亮 UTF-16/grapheme 错位** | [未修] | commit `4fa4946` 声称 "bug-2 fix",但 `toGrapheneRange(in:)` **从未编写**;actor fuzzy-range 处理(`SearchActor.swift:132-135`)与 legacy `Search.swift:89-95` **逐字节相同** |
| **07-F-013 搜索/高亮截断不一致→静默丢高亮** | [未修] | 搜索截断 5000(fuzzy)/1000(regex),高亮截断 500(`AttributedString(title.shortened(to: 500))`),不同源无 `TextLimits`。正则命中在 600–1000 字符区间,`AttributedString.Index(within:)` 返回 nil 静默丢 |
| mixed 三遍无短路 | [未修] | `LT-SEARCH-02`:`mixedSearch` 仍 `simple→regexp→fuzzy` 三遍 |
| resize 在搜索热路径 | [未修] | `LT-MAIN-05`:`History.swift:824`/`:875` 同步 `needsResize = true` |
| `showSpecialSymbols` 全量重生成标题 | [未修] | `LT-MAIN-02`:`History.swift:192-198` 仍对全 `items` 调 `generateTitle()` |
| 截断单位不统一(grapheme vs byte) | [未修] | `LT-UTF8-01` / 07-F-012 |
| G-search 闸门 | [部分] | `TextSearchPerformanceTests` baseline-only、**直接测 legacy `Search()` 而非新 actor**,off-main 收益未被 CI 证明 |

### 2.4 Image(图片管线)

| 项 | 状态 | 说明 |
|---|---|---|
| 解码/缩略图/预览在主线程 | [已修] | `IMG-001/002/003/004`:BS-3 已用 `ImageProcessor` actor + `CGImageSourceCreateThumbnailAtIndex` 降采样,off-main |
| 预览封顶 800px | [已修] | BS-4.10(原 `visibleFrame` ~50MiB/张) |
| `imageData` 全表 fault | [部分] | `img-fullres-dup-storage`:BS-6 已 lazy(`HistoryItemDecorator.imageDataCache`),但**冷开仍会因 `load()` 全表 fault 而触发**;双份(blob+位图)问题在 `imageDataCache` 仍存 |
| `DecodedImageCache` | [死代码] | `MemoryGovernance.swift:61`:`setImage/image(for:)` **零调用方**,只有 `evict`/`purgeAll` 被调。"解码位图按可视区限界"核心目标**从未实现**,preview 位图仍 per-decorator 持有 |
| `releaseTransientImages(.previewHidden)` | [死代码] | 枚举 case 零调用方;`FloatingPanel.close()` 从不调 |
| `ApplicationImageCache` 无界字典 + fd DispatchSource | [已修] | `IMG-010/011`:NSCache 限界 128 + fd guard(M4)；E5 后由 History decorator factory 显式拥有并经 memory-governance capability 清理，无进程级 `.shared`。 |
| `ColorImage` 主线程合成 | [已修] | `IMG-019`:NSCache 限界(M9) |
| 缩略图缓存键 FNV-1a | [部分] | `IMG-caching-key`:`ImageProcessor.thumbnail` 用 FNV;待统一 xxh3_64(已接入去重热路径,缓存键未切) |

> 已删除项:Vision OCR(图片项用空标题 `""`,2026-06-14)——`IMG-005/014/015/036` 与 `07-F-008` 全部 WONTFIX。

### 2.5 UI / 渲染

| 项 | 状态 | 说明 |
|---|---|---|
| 渲染风暴(动画→每帧 layout+CoreText 重测) | [已修] | 2026-06-26 修复:`titlePreviewLimit=1000` + `.middle` 截断放大;固定行高 + hover-no-scroll + preview cancel + 即时 snap+淡入 |
| 混合列表 layout 反馈风暴 | [已修] | `LazyVStack` layout-feedback(perf-mixed 394s hang)已修:固定行几何 + hover-no-scroll + preview cancel |
| `@unchecked Sendable` on HistoryItemDecorator/AppDelegate | [已修] | `IMG-035`/`historyitem-unchecked-sendable`:BS-7 实际归零(grep 0 标注),complete 模式 CI 绿 |
| `WrappingTextView` 双次 sizeThatFits | [未修] | `LT-RENDER-02` |
| `.drawingGroup()` 每行每重绘栅格化 | [部分] | `LT-RENDER-03`:依赖 `attributedTitle` 仅在 ranges 变时改(高亮 memoize 未做) |
| `updateUnpinnedShortcuts` 双遍赋值 | [未修] | `updateunpinned-double-pass` |

---

## 3. 数据安全

### 3.1 SwiftData pending-vs-saved 不对称(关键)

- **`fetch` 遵守 pending 改动**:带未保存改动的 fetch 会读到 in-memory 态。
- **`delete(model:where:)` 仅匹配已提交 store 状态**:predicate delete 不看 pending。
- **规则:任何 predicate delete 之前必须先 `save()`**,否则 predicate 与可见态不一致。`clear()` 的 `transaction { try? delete... }` 模式因内层 `try?` 吞错而**语义上不算事务**(07-F-014)。

### 3.2 单事务摄取

ingestor 一次复制只发**一个**后台 context 事务(insert + 去重合并 + 容量裁剪在同一事务)。失败的旧形态是单次复制最多 3 次独立 `processPendingChanges + save`(`add-does-3-pending-changes-saves`)。

### 3.3 仍未修的高危数据安全项

| finding-id | 位置 | 问题 |
|---|---|---|
| 07-F-001 | `Storage.swift:37-72` | `recoverContainer` 容器加载失败即**删 SQLite/WAL/SHM**(`removeStoreFiles`)——不可逆丢全部历史 |
| 07-F-002 / 07-F-003 | `History.swift` 多处 | 全局 `try?` 吞所有 save/delete/fetch 错误,内存态与磁盘态可能分叉 |
| 07-F-017 | `HistoryItem.swift:260-267` | `dataFromFileIfAllowed`:`try?` 取 fileSize 失败→`(fileSize ?? 0) <= cap` 恒真→无界文件 `Data(contentsOf:)` 可 OOM |
| 07-F-032 | `Collection+Surrounding.swift:18-32` | `item(before:)` 首元素 `offsetBy: -1` **运行时 trap**(可达:首项按 ↑) |
| 07-F-013 / 07-F-010 | `Search.swift` / `HistoryItemDecorator.swift` | 见 §2.3(正确性) |

### 3.4 正确代码(勿改)

`validUTF8PrefixLength`(`ClipboardByteProcessor.cpp:19-76`,完整 UTF-8 校验含 overlong/代理对/`>0x10FFFF` 拒绝);`fnv1a64`/`xxh3_64`(常数时间、无溢出);`dataLikelyEqual` 指纹命中后**仍跑 `lhs == rhs` 全比较**(碰撞安全,07-F-029);`@Relationship(deleteRule: .cascade)` 正确级联删 contents;`HistoryItemContent.maxValueSize` 在 ingest 封顶单 blob;`Search.isLikelyUnsafeRegularExpression` 拒嵌套量词正则。

---

## 4. 内存(2026-06-27 实测真相)

### 4.1 判定

| 目标 | 判定 | 依据 |
|---|---|---|
| **50 MB** | ❌ 不可能 | 框架不可压缩地板 ≈ **62 MB**(任何剪贴板内容之前)。50 MB 在地板之下 |
| **100 MB** | ❌ 不可达 | 地板 62 + 内容 blob + AG 图 + 缓存 + 窗口开 ~110–130MB 框架成本 |
| **现实稳态** | ~85–100 MB | 当前 6h dump=135MB,可再榨 ~20–35MB |

> 06-25 短启动(2 分钟)= 102MB 是**假信号**——掩盖了滞留斜率;6h 才暴露真实稳态 135MB 且仍在涨。leaks 仅 19KB(**不是泄漏**)。

### 4.2 滞留根因:`mainContext` 是进程级累积器,从不回收

机制(`docs/audit/2026-06-27-memory-floor-and-retention/03-retention-root-cause.md`):
1. `History.load()`(`History.swift:218`)裸 fetch 全表 → fault + 物质化全部 `HistoryItem`。
2. 读 `item.contents`/`item.imageData` 进一步 fault 每项的 `HistoryItemContent` 行 + `__DataStorage._bytes` blob。
3. **物质化后 `mainContext` 的行缓存(`_KKMDBackingData`)永久持有**——删除项的 `@Model` 从 store 移除了,但活动 `mainContext` 里物质化的行缓存**从不清理** → 单调增长。

heap 证据:624 个 `HistoryItemContent` + 624 个 `_KKMDBackingData`(对应 556 个 `__DataStorage._bytes` blob = **17.5 MB**);624/185 ≈ 3.4 内容/项,符合多类型结构(**不是孤儿,是全表 fault**)。Maccy 自己的模型对象仅 ~0.15MB——135MB 里 ~95% 是框架工作集 + 内容 blob + 视图图深度。

### 4.3 两个反直觉的坑

1. **`mainContext.reset()` 是陷阱**:会重新 fault 全表,直接退回冷开卡顿,并破坏增量 `consume` 路径(`decorator.item` 失效)。**别走这条捷径**回收 blob。
2. **SwiftData 没有单行 fault-out API**:`refresh` 是从 store 重填(更满),非清空。→ 光把 decorator 窗口化(C5)**释放不了底层 blob**。**F1(把大内容移出 SwiftData,独立 blob 存储按 id 索引)从"可选"升为"可能强制项"**——是唯一能在保持 `@Model` 身份的同时逐项回收 blob 的 sound 路径。

### 4.4 已落地(别再做)

`sessionLog`→`PersistentIdentifier`(M3,不再持 `@Model`);5 个无界缓存全 NSCache(ApplicationImageCache 128 / ignoredRegexps 64 / ColorImage 64+cost / ThumbnailCache 两层);`imageData` lazy(BS-6);HotKey + TIS 泄漏已修(M1/M2);`autoreleasepool`(M6);`MemoryGovernance` + `VisibilityTracker` + `releaseTransientImages`(C1/C2/C3);preview 系统改造(可配置尺寸/文本上限、即时 snap+淡入、previewed item 与 lead 选择解耦);U1 `.help` gate(唯一 UX-safe 内存 win)。

### 4.5 地板构成(为何 62MB 硬)

框架 `__TEXT`(首次触碰 COW 进程私有页,~45MB,**无法 evict**)+ 框架可写状态(~10MB)+ AttributeGraph 最小图(~5MB)+ libmalloc/zone/page table/Stack/IOAccelerator(~2MB)。41.7MB `non-object` 盲区主要(推断 ~66%,AG zone 占 109K 分配的 72K)是 **AttributeGraph 视图图节点体**——随已实现视图节点数线性增长,可减 ~30–45% 但留 ~17–20MB AG 不可减核。

### 4.6 待做(去重后真实 ~20–35MB,C5/C7/F1 共享 17.5MB blob 池**不能相加**)

1. 延迟 `HistoryItem.contents` fault(C7):3–8MB
2. AttributeGraph 视图树瘦身:3–8MB(需 MallocStackLogging 实证 AG 占比)
3. 接通 `releaseTransientImages(.previewHidden)`(C6,代码已存在零调用):1–2MB(免费)
4. F1 独立 blob 存储(BS-8):把 blob 池压到 ~3–5MB 再省 ~8–12MB

`VisibleWindowLoader` 已由 D1 否决并删除：06-27 实测确认其内存收益约 0，
且会破坏完整历史搜索；07-12 的等价语义候选也只有噪声级启动差异。

**前置**:`MallocStackLogging=1` 重抓(D1,零代码),把 41.7MB 盲区从推断变实测。

---

## 5. 完成度一览(BS-0 → BS-8)

> 完成度以**源码现状**为准,非 commit message。**"路线图完成"是假象**——50 个小步骤勾选框全 `[ ]`,CI 绿 ≠ 规范做完。详见 `docs/audit/2026-06-28-roadmap-bs5-bs8-gap-audit/`。

| 大步骤 | 完成度 | 状态 | 核心目标 | headline 缺口 |
|---|---|---|---|---|
| **BS-0** 安全 | 完成 | — | 数据安全基线 | — |
| **BS-1** 并发脚手架 | 完成 | — | DTO/actor/context 模型 | — |
| **BS-2** 摄取→actor | 完成 | — | copy 路径离主线程 | 标题/富文本仍回主线程 |
| **BS-3** 图片管线 | 完成 | — | ImageIO 降采样 off-main | 缩略图缓存键未切 xxh3 |
| **BS-4** 数据管线 | 部分 | ⚠️ | 增量 consume/reconcile | D1 已量测保留完整 load 并删除 loader 死代码；`findSimilarItem`/`History.add` 死代码未删 |
| **BS-5** 文本搜索 | **2/13** | ❌ | off-main ✓(已达成) | **07-F-010 高亮错位 commit 夸大("bug-2 fix" 是空描述);07-F-013 静默丢高亮未修**;5.1/5.2/5.5/5.7/5.8/5.9/5.10 跳过;G-search 测 legacy 非 actor |
| **BS-6** 内存治理 | **5/12** | ❌ | decoded-image bounded to visible | **`DecodedImageCache` 死代码**(`setImage/image(for:)` 零调用);`.previewHidden` 死枚举;G-memory 闸门未建;6.11 测试套件 0/6 |
| **BS-7** Swift 6 | **13/17** | ⚠️ | complete 模式 CI 绿、零 @unchecked ✓(达成) | **7.13(唯一行为级改动)跳过**:`synchronizeItemPin/Title` 仍 recursive `withObservationTracking`+`DispatchQueue.main.async`;4 个测试文件缺;`Sorter`/`Throttler` 仍裸 class |
| **BS-8** C++/指纹 | **4/8** | ⚠️ | xxh3 接入 live 去重 ✓(达成) | **8.5 旧数据行 lazy backfill 缺失**(老行永远 nil,落回全量 `==`);8.3 桥加固丢弃(`enumerateByteRanges` 流式 08-F-004、UTF-8 防御 03-LT-CPP-01 未做);8.8 测试 0/4,FNV baseline 切换前未捕获 |

**系统性模式**:核心热路径做、外围正确性/限界/测试/文档勾选丢;偏差只记 commit message 或旁侧文档(违反 CLAUDE.md "记录偏差在 audit docs");规范要求 ~19 个新测试文件,实际只建 `SearchActorTests.swift` 一个。

### 5.1 优先级最高的补全(按价值/风险)

1. **BS-5 07-F-013**:对齐 highlight 与搜索截断到同一 `TextLimits`,越界改 clamp+log。
2. **BS-5 07-F-010**:写 emoji fuzzy 高亮落位断言,核实 Fuse 偏移语义;若 UTF-16 再补 `toGrapheneRange`,否则删夸大注释。
3. **BS-8 8.5 backfill**:补老数据行指纹回填。
4. **BS-6 `DecodedImageCache`**:要么接通要么删除死代码。
5. **BS-4 legacy `History.add` 清理**:先迁移测试，再删除已退出生产路径的 adapter/legacy 写路径。

---

## 6. finding-id 词汇表

历史审计用三套 finding-id 前缀。下表给出含义 + 当前状态,供源码注释清理与未来读者解码。

### 6.1 `01-` / `04-`(并发/数据管线,kebab-case)

| finding-id | 含义 | 当前状态 |
|---|---|---|
| `load-no-pipeline-offload` | `load()` 全表 fetch+排序+装饰同步在主线程,无 limit/fault/batch | 未修(`History.swift:218`) |
| `findsimilar-full-refetch` | `findSimilarItem()` 每次复制重 fetch 全表 + O(n) 比对 | 死代码(live 走 SignatureIndex) |
| `pasteboard-polling-callback-heavy` | Timer 回调整条摄取管线同步在主线程 | 已修(actor) |
| `no-background-modelcontext` | 只有 mainContext,无后台 context/actor | 部分(后台 context 已用,load 仍 main) |
| `add-does-3-pending-changes-saves` | 单复制最多 3 次独立 save | 已修(单事务) |
| `limit-multi-save-storm` | 容量裁剪逐条 delete+save | 部分 |
| `insert-resorts-whole-array` | 插入时整表重排找插入点 | 已修(二分插入) |
| `search-throttle-still-runs-main` | 搜索 throttler 只合流,全量扫仍在主线程 | 已修(SearchActor) |
| `richtext-sync-decode-on-ingest` | `richText()` 同步 `NSAttributedString(rtf:/html:)` 在主线程 | 未修 |
| `decorator-init-main-decode-icon` | decorator init 同步解析 app icon | 已修(NSCache + lazy) |
| `historyitem-unchecked-sendable` / `appdelegate-unchecked-sendable` | `@unchecked Sendable` 掩盖可变状态 | 已修(BS-7 归零) |

### 6.2 `02-`(图片管线,IMG-###)

| finding-id | 含义 | 当前状态 |
|---|---|---|
| `IMG-001/002/003/004` | 解码/resize/预览超大/"async" Task 实为 @MainActor 全在主线程 | 已修(BS-3 ImageProcessor actor + ImageIO 降采样) |
| `IMG-005/014/015/036` | Vision OCR 主线程 | WONTFIX(OCR 删除) |
| `IMG-008` | 全分辨率 imageData + decodedImage + preview + thumbnail 同时持有 | 部分(imageData lazy;双份仍存) |
| `IMG-010/011` | per-bundle DispatchSource + 无界 ApplicationImageCache | 已修(NSCache 128 + fd guard) |
| `IMG-019` | `ColorImage.from` 每渲染合成 12x12 主线程 | 已修(NSCache) |
| `IMG-035` | `@unchecked Sendable` on decorator | 已修 |
| `img-fullres-dup-storage` | 全分辨率 imageData 在装饰器复制第二份(SwiftData 行内 + imageData) | 部分(lazy) |

### 6.3 `03-`(大文本,LT-###)

| finding-id | 含义 | 当前状态 |
|---|---|---|
| `LT-MAIN-01` | 同步去重扫 + 标题生成在主线程,per copy | 已修(live 走 actor) |
| `LT-MAIN-02` | `showSpecialSymbols` 切换重生成所有 item 标题(≥4 regex/replace 遍) | 未修 |
| `LT-MAIN-05` | resize 调度在搜索 throttle 块内 | 未修 |
| `LT-SEARCH-01` | 标题截断(5000/1000)静默藏匹配 + 截断点切 grapheme | 未修 |
| `LT-SEARCH-02` | mixed 三遍无短路 | 未修 |
| `LT-UTF8-01` | `shortened(to:)` 按 grapheme 切,与 byte 版 `stringPrefix` 单位不一致 | 未修 |
| `LT-CPP-02/03/07` | FNV-1a 慢 / 指纹非对称重算(lhs 每次重哈希)/ 哈希循环不可向量化 | 部分(BS-8 xxh3 + 持久化列修 03;缓存键未切) |
| `LT-CPP-01` | `index+width` 溢出 / `UInt(maxBytes)` 截断 | 未修(BS-8.3 丢弃) |
| `LT-RENDER-01/02/03` | AttributedString 逐键重建 / WrappingTextView 双测 / `.drawingGroup` 每行栅格化 | 部分/未修/部分 |

### 6.4 `07-`(数据安全,F-### / 07-F-###)

> 注:06-28 缺口审计用 `07-F-NNN` 前缀引用本组。下表是仍活跃的 finding。

| finding-id | 含义 | 当前状态 |
|---|---|---|
| `07-F-001` | `recoverContainer` 删 SQLite 文件丢数据 | 未修 |
| `07-F-002/003` | 全局 `try?` 吞 save/delete 错误 + save 失败仍保留 in-memory | 未修 |
| `07-F-008` | OCR Task fire-and-forget 改 `@Model` | WONTFIX(OCR 删除) |
| `07-F-010` | Fuse 返回 UTF-16 偏移,`index(offsetBy:)` 按 grapheme → emoji/CJK 高亮错位 | **未修(commit 夸大)** |
| `07-F-012` | `shortened(to:)` grapheme vs `stringPrefix` byte 单位不一致 | 未修 |
| `07-F-013` | highlight 截断 500 vs 搜索截断 5000/1000 → 匹配 >500 字符静默丢高亮 | **未修** |
| `07-F-014/015` | `clear()` 事务内 `try?` 吞错(非真事务)+ item/content predicate 不对称 | 未修 |
| `07-F-017` | `dataFromFileIfAllowed` fileSize `try?` 失败→恒真→无界文件 OOM | 未修 |
| `07-F-029` | FNV 非密码学哈希 | 安全(命中后仍跑全比较) |
| `07-F-032` | `item(before:)` 首元素 `offsetBy:-1` trap | 未修 |

### 6.5 `08-`(C++ interop,08-F-###)

| finding-id | 含义 | 当前状态 |
|---|---|---|
| `08-F-001` | lhs 指纹每次比对重算(非对称)→ dedup 优化失效 | 已修(BS-8.6 持久化列 + BS-8.5 懒回填 backfill,2026-07-03 CI 绿 run `28664372473`) |
| `08-F-004` | `data.bytes` 非连续 NSData 未流式(`enumerateByteRanges`) | 未修(BS-8.3 丢弃) |
| `08-F-009` | `dataLikelyEqual` 默认参数陷阱(lhsFingerprint 默认 nil) | 已修(BS-8.4 对称双指纹) |

### 6.6 缓存/内存杠杆代号(M/C/F/U/D 系列,06-27)

| 代号 | 含义 | 状态 |
|---|---|---|
| `M1/M2` | HotKey / TIS 泄漏 | 已修 |
| `M3` | `sessionLog` → `PersistentIdentifier` | 已修 |
| `M4/M5/M9` | ApplicationImageCache / ignoredRegexps / ColorImage NSCache | 已修 |
| `C1/C2/C3` | MemoryGovernance / VisibilityTracker / releaseTransientImages | 已修(框架) |
| `C5` | 接入 `VisibleWindowLoader`(load 全表→可见窗口) | **D1 否决并删除**（~0 内存价值、破坏完整搜索、等价启动候选仅快约 1%） |
| `C6` | 接通 `releaseTransientImages(.previewHidden)` | **未做(死枚举)** |
| `C7` | 延迟 `HistoryItem.contents` fault | 未做 |
| `F1` | 大内容移出 SwiftData,独立 blob 存储(BS-8) | 未做(升为可能强制项) |
| `U1` | AttributeGraph 视图树瘦身 / `.help` gate | `.help` gate 已做;视图树瘦身未做 |
| `D1` | `MallocStackLogging=1` 重抓盲区归因 | 未做(前置) |

---

*本文档替代(非补充)2026-06-14 深度审查组(`00-overview`~`09-roadmap`)与 2026-06-25 模块分析组(`03-`~`07-module-analysis-*`)作为当前架构权威;两者将被删除。逐小步规范仍在 `2026-06-14/roadmap/step-X-*.md`,完成度审计在 `2026-06-28-roadmap-bs5-bs8-gap-audit/`,内存实测在 `2026-06-27-memory-floor-and-retention/`。*
