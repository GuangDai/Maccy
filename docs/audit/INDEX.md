# docs/audit/ — 权威导航中心

> **本文件是审计文档仓库的单一权威导航中心,自包含。** 阅读任何审计文档前先读此页,以避免把"冻结的设计意图"或"历史快照"误读为"当前状态"。
>
> 最近更新:**2026-07-11**(XcodeGen M0–M3 production cutover complete at `94ca913`: `project.yml` is truth; normal CI/release regenerate twice and reject drift; full master and release dry-runs green. `NEW-storage-load-models-2` cleanup at `91d76b8`; E3 at `32320cf`; E1 at `cd368ea`.) Earlier **2026-07-10**:`2026-07-10-history-split-plan/` — expanded B0 authority: **defer History split**; D4 measure-first (`onEvent` widen); DS-022-standalone hollow-as-B1; full **SwiftLint 1000/1000 policy audit**; forcing-gate + S0–S7 execution board. Expands `history-split-grilling/00-decision.md`. + `2026-07-10-master-roadmap.md` global post-Wave-A order. Earlier 2026-07-09:`2026-07-09-design-audit-verification/` — `/grill-with-docs` verification of the design-structure audit: 13-agent verify+refute workflow + firsthand grep. **27/34 findings confirmed verbatim; 6 severity-overstated (DS-002 Crit→High etc.); DS-019 refuted; 19 new issues** incl. a silent session-wide dedup-disable (`NEW-dedup-ids-1`) and the `searchGeneration` bug-class; 16 glossary/location fixes. Recalibrates the playbook's Wave A. HEAD `6cd37c8`. Same day also **rewrote** `2026-07-09-design-structure-audit/` in **English only**, ~3.3k lines: step-by-step data-flow traces (`02`), evidence-backed findings DS-001…034 (`17`), per-module deep dives, master playbook (`19`). HEAD `6cd37c8`. Supersedes the earlier Chinese draft of the same folder.). Earlier 2026-07-05:`2026-07-05-applicationimage-mainactor-crash/`. Phase-1 整理(2026-06-29)仍适用。

## 0. 三大权威源 + spec-of-record(reading order)

| 角色 | 路径 | 是什么 |
|------|------|--------|
| **路线图完成度权威** | [`2026-06-28-roadmap-bs5-bs8-gap-audit/00-summary.md`](2026-06-28-roadmap-bs5-bs8-gap-audit/00-summary.md) | BS-5/6/7/8 的真实完成度(BS-5 2/13、BS-6 5/12、BS-7 13/17、BS-8 4/8),推翻"路线图已完成"的误读;逐步骤缺口见 `01`–`04`,源码 BS 标注审计见 `05`,删除提案见 `06`。**CI 绿 ≠ spec 完成。** |
| **内存权威** | [`2026-06-27-memory-floor-and-retention/`](2026-06-27-memory-floor-and-retention/) | 06-27 6h 实测=135MB(驻留非泄漏);框架底 ~62MB;**100MB 不可达**(窗口常开 ~110-130MB 为框架成本);推翻 06-25"目标已在 102MB 达成"假信号(2 分钟短启动隐藏了斜率);D1(MallocStackLogging)被重新提升为关键前置。原始捕获数据见 `captures/`。 |
| **当前架构参考** | [`architecture-and-root-causes.md`](architecture-and-root-causes.md) | 当前架构/数据流/根因图谱参考。蒸馏自已删除的 06-14 深度审计(00-08、09、99)与 06-25 模块代码级分析,作为单一架构真相源。 |
| **路线图设计意图(冻结,spec-of-record)** | [`2026-06-14/roadmap/`](2026-06-14/roadmap/) | BS-0→BS-8 的原始规格(README + A/B/C + step-0..8)。这是每一步被**测量完成度所依据的 spec**,不是当前状态。每个文件顶部保留一条冻结 banner;step-0..8 另附一条 06-28 完成度状态行。 |

> **关于已删除的过程文档**:06-15/20/21/22/23/24/25 的过程手记、已落地修复记录、superpowers 设计历史,以及 06-14 的深度审计正文(00-overview.md..99-verification.md),已在 Phase-1 整理中删除。其**承重结论未丢失**:架构/根因并入 [`architecture-and-root-causes.md`](architecture-and-root-causes.md),路线图状态以 06-28 gap-audit 为准,内存以 06-27 为准,过程教训(崩溃诊断方法学、SwiftData pending-vs-saved、Duration→ms 1000× bug、MainThreadProbe drain、ingest=reconcile 而非 findSimilar 等)保存在用户记忆文件(`~/.claude/.../MEMORY.md` 索引)中。

## 1. 当前真值一览(at a glance)

### 路线图完成度(2026-06-28 审计,见 06-28 gap-audit)
- **BS-0**:完成(止血/构建卫生)。
- **BS-1**:完成(并发脚手架,纯加法)。
- **BS-2**:完成(摄取管线迁入 actor)。
- **BS-3**:完成(图片管线;IMG-023 预览取消 stopgap 已补)。
- **BS-4**:部分完成 — 4.2/4.5(去重收敛)、4.4a(增量 reconcile,G-copy 9.34→0.99ms)、4.7(预温)落地;4.3(load 重写)/4.6/4.8 延后;**`VisibleWindowLoader.fetchWindow` 仍是死代码**(从未接入 `load()`)。
- **BS-5**:部分完成 **2/13** — `SearchActor` + generation 守卫真实且正确;**但 07-F-010(高亮 UTF-16/字素错位)与 07-F-013(静默高亮丢弃)未修**,虽提交 `4fa4946` 称"bug-2 fix"(`toGrapheneRange` 从未编写);resize 仍在热路径;`showSpecialSymbols` 未触碰;G-search gate 仅基线测量 legacy `Search()`。**→ 用户决定 2026-07-04「重设计」BS-5(扩范围:全文搜索 + 预览高亮/滚动 + 模式循环按钮),见 `2026-07-04-bs5-search-redesign/`。**
- **BS-6**:部分完成 **5/12** — `DecodedImageCache` 为**死代码**(`setImage`/`image(for:)` 零调用);`.previewHidden` 零调用方;6 个测试文件缺失;G-memory gate 从未构建。
- **BS-7**:大部分完成 **13/17**(最扎实)— Swift 6.0 complete mode 上线,零 `@unchecked`/`nonisolated(unsafe)`;7.13(唯一行为变更)**被跳过**;4 个测试文件缺失;52 处冗余 per-method `@MainActor` 残留。
- **BS-8**:部分完成 **4/8** — 核心真实(xxh3 已接入实时去重 `c6821c4`、对称 `dataLikelyEqual`、`fingerprint` 列);**未披露缺口**:8.5 懒回填 backfill **缺失**(旧行保持 nil→全表 `==`)、8.3 桥接加固被砍、8.8 四个测试文件 + FNV 基线缺失。
- **50 个步骤文档 checkbox 全部未勾选**(spec-of-record 状态未回填)。

### 性能(当前 HEAD)
- `load()` 200 项 ~44–55ms;搜索 ~3.9ms/key;copy ~1.7ms;预览 ~15ms。(旧"load() 0.91s"为 pre-BS-4,已废。)

### 实时摄取路径
- 实时 per-copy 路径:`BackgroundClipboardIngestor`→`History.consume`→`reconcileWithStore`(4.4a 经 `model(for:)` + 二分插入增量;G-copy 9.34→0.99ms)。`findSimilarItem` / `History.add` 在生产中已死。

## 2. 存活文档清单(Phase-1 整理后)

> 仅列出当前存活文档。已删除的过程/手记/中间分析文档不在此列(见 §0 末尾说明)。
> role:`A`=authority(当前权威)/`OA`=original-archive(冻结原始档案)/`data`=原始捕获数据。

### 2026-06-14 — 路线图 spec-of-record(全部 OA,冻结)

| 路径 | role | 摘要 |
|------|------|------|
| `2026-06-14/roadmap/README.md` | OA | 路线图索引/用法(BS-0→8 依赖图、编译边界规则)。 |
| `2026-06-14/roadmap/A-architecture-target.md` | OA | 目标架构(Main vs Background-actor 隔离 + DTO 目录)。 |
| `2026-06-14/roadmap/B-test-strategy.md` | OA | 测试策略(双倍/夹具目录、G-* 性能 gate)。 |
| `2026-06-14/roadmap/C-complexity-and-limits.md` | OA | 复杂度/I-O/时延/内存预算 spec(<300MiB 目标)。 |
| `2026-06-14/roadmap/step-0-safety.md` | OA | BS-0 spec(止血:首项插入陷阱、recoverContainer 不删、try? 日志)。 |
| `2026-06-14/roadmap/step-1-concurrency-scaffolding.md` | OA | BS-1 spec(后台上下文、Sendable DTO、SignatureIndex、协议)。 |
| `2026-06-14/roadmap/step-2-ingest-to-actor.md` | OA | BS-2 spec(摄取→actor,单事务写、StoreEvent)。 |
| `2026-06-14/roadmap/step-3-image-pipeline.md` | OA | BS-3 spec(ImageIO 降采样、off-main 解码、ThumbnailCache)。 |
| `2026-06-14/roadmap/step-4-data-pipeline.md` | OA | BS-4 spec(签名索引去重、二分插入、批量 load)。 |
| `2026-06-14/roadmap/step-5-text-search.md` | OA | BS-5 spec(SearchEngine actor、HighlightRange 修复)。 |
| `2026-06-14/roadmap/step-6-memory.md` | OA | BS-6 spec(NSCache、可视区/告警回收、去重 full-res)。 |
| `2026-06-14/roadmap/step-7-swift6.md` | OA | BS-7 spec(minimal→targeted→complete 分阶迁移)。 |
| `2026-06-14/roadmap/step-8-cpp.md` | OA | BS-8 spec(xxh3、持久化指纹列、对称 DTO、加固桥接)。 |

### 当前架构参考(A)

| 路径 | role | 摘要 |
|------|------|------|
| `architecture-and-root-causes.md` | A | 当前架构/数据流/根因图谱(蒸馏自已删除的 06-14 深度审计 + 06-25 模块分析)。 |

### 2026-06-27 — 内存权威套件(A)

| 路径 | role | 摘要 |
|------|------|------|
| `2026-06-27-memory-floor-and-retention/README.md` | A | 内存权威索引。 |
| `2026-06-27-memory-floor-and-retention/00-executive-summary.md` | A | 推翻 102MB 假信号;认定框架底 ~62MB、100MB 不可达。 |
| `2026-06-27-memory-floor-and-retention/01-dump-decomposition-06-27.md` | A | 135MB dump 分解(leaks 19KB=非泄漏;41.7MB non-object 盲区)。 |
| `2026-06-27-memory-floor-and-retention/02-framework-floor.md` | A | 证明 ~62MB 框架底(COW __TEXT ~45MB + 状态 ~10MB + AG 图 ~5MB + 运行时 ~2MB)。 |
| `2026-06-27-memory-floor-and-retention/03-retention-root-cause.md` | A | 33MB/6h 驻留根因(mainContext 进程级累积器;`History.load` 全表 fault)。 |
| `2026-06-27-memory-floor-and-retention/04-status-vs-master-plan.md` | A | 06-27 状态账本(对照 06-25 master plan)。 |
| `2026-06-27-memory-floor-and-retention/05-action-plan.md` | A | 内存行动计划(C5/C7/F1 共享同一 17.5MB blob 池,F1 覆盖前两者)。 |
| `2026-06-27-memory-floor-and-retention/06-gating-diagnostics.md` | A | MallocStackLogging 重抓协议(D1,关键前置)。 |
| `2026-06-27-memory-floor-and-retention/07-uxsafe-verification-verdicts.md` | A | UX-safe 杠杆判定(DecodedImageCache 死代码、C5 不 sound、U1 .help gate 唯一 win DONE)。 |
| `2026-06-27-memory-floor-and-retention/08-d1-findings.md` | A | D1 首批 MSL 归因数据(46MB 为 168K 小分配长尾)。 |
| `2026-06-27-memory-floor-and-retention/captures/` | OA/data | D1 原始抓取数据(脚本 + 目录),永不删除。 |

### 2026-06-28 — 路线图完成度权威(A)

| 路径 | role | 摘要 |
|------|------|------|
| `2026-06-28-roadmap-bs5-bs8-gap-audit/00-summary.md` | A | **路线图完成度权威**(BS-5 2/13、BS-6 5/12、BS-7 13/17、BS-8 4/8)。 |
| `2026-06-28-roadmap-bs5-bs8-gap-audit/01-bs5-text-search-gaps.md` | A | BS-5 缺口(07-F-010 `toGrapheneRange` 未写、07-F-013 静默丢弃)。 |
| `2026-06-28-roadmap-bs5-bs8-gap-audit/02-bs6-memory-gaps.md` | A | BS-6 缺口(DecodedImageCache 死代码、G-memory gate 未建)。 |
| `2026-06-28-roadmap-bs5-bs8-gap-audit/03-bs7-swift6-gaps.md` | A | BS-7 缺口(7.13 跳过、4 测试文件缺)。 |
| `2026-06-28-roadmap-bs5-bs8-gap-audit/04-bs8-cpp-gaps.md` | A | BS-8 缺口(8.5 backfill 缺、8.3 加固砍、8.8 测试缺)。 |
| `2026-06-28-roadmap-bs5-bs8-gap-audit/05-source-bs-annotation-audit.md` | A | 源码 BS-x 标注审计(checklist for cleanup pass)。 |
| `2026-06-28-roadmap-bs5-bs8-gap-audit/06-deletion-proposal.md` | A | Phase-1 文档删除提案。 |

### 2026-07-03 — BS-6/7/8 完成执行计划(A,active)

| 路径 | role | 摘要 |
|------|------|------|
| `2026-07-03-bs678-completion-plan/README.md` | A | **BS-6/7/8 补全到 spec 的执行计划**:验证后真值(4-agent 验证 HEAD `8e0ba2c`)、测试清单(已有 vs 待补,去重)、按风险/价值排序的小步骤序列(BS-8→7→6)。 |
| `2026-07-03-bs678-completion-plan/decisions.md` | A | 4 个决策叉点 ADR(DecodedImageCache 接通 / 8.5 惰性 signal-to-actor 回填 / 7.13 mirror-TDD / perf-as-class)— **用户离席期间代为决定,回归后优先复核**。 |
| `2026-07-03-bs678-completion-plan/glossary.md` | A | 术语 + finding-id(07-F/08-F/03-LT/M-C-F-U-D)词汇表 + 不变性清单。 |

### 2026-07-04 — BS-5 搜索重设计计划(A,active)

| 路径 | role | 摘要 |
|------|------|------|
| `2026-07-04-bs5-search-redesign/README.md` | A | **BS-5 重设计执行计划**(超冻结 spec):3-agent 验证当前管线(预览/内容/索引)、当前真值表、三轨序列 T0(模式循环按钮)/T1(标题域正确性)/T2(全文搜索)/T3(预览高亮+滚动)、测试清单、**实时进度日志(每步 CI 绿追加)**。 |
| `2026-07-04-bs5-search-redesign/decisions.md` | A | 6 ADR(用户会话内全确认):ADR-1 循环按钮替换放大镜+缩写+仅点击;**ADR-2 全文索引先无索引+测量后按需加**(推翻 Q4 标题域下的 index 选择,因全文内存数学 + <16ms 闸门针对主线程);ADR-3 fuzzy 标题+正文前缀;ADR-4 预览分阶段(NSTextView 解 3000 封顶);ADR-5 body 封顶 32KB;ADR-6 searchText 持久化列+语料移 actor。 |
| `2026-07-04-bs5-search-redesign/glossary.md` | A | 术语(searchText/body cache/Stage1-2/Track2-index/TextLimits/PreviewTextRep/inBody)+ finding-id(03-LT/07-F)词汇 + 不变量。 |

### 2026-07-05 — ApplicationImage `@MainActor` 崩溃分析(A,active)

| 路径 | role | 摘要 |
|------|------|------|
| `2026-07-05-applicationimage-mainactor-crash/README.md` | A | **生产崩溃分析 + 同类隔离风险排查方法学**。`ApplicationImage.nsImage.getter` 的 `setEventHandler` 闭包因 `DispatchSourceHandler` 非 `@Sendable` + `@MainActor` 类(SE-0420 继承)带运行时序言;`queue: .global()` 在后台回调 → `dispatch_assert_queue_fail` → `SIGTRAP`。潜伏 ~14h(等 app bundle 删除/重命名触发)。**证伪 06-28 gap-audit 7.4"经 main hop 隔离安全"误判**。**2026-07-06 已修(`c4b91ee`)**:`queue: .global()` → `.main` + 删冗余内层 `main.async` hop(原"序言后 hop"结构是脚枪)。含 C1–C5 排查清单 + 全量预扫描候选表(仅 ApplicationImage 确认 trap;`deinit+assumeIsolated`+NSCache 后台驱逐 §8 待验证)。 |

### 2026-07-09 — Design structure audit (English rewrite, A, active)

| Path | role | Summary |
|------|------|---------|
| [`2026-07-09-design-structure-audit/README.md`](2026-07-09-design-structure-audit/README.md) | A | **English-only** design/structure/domain/pipeline/cohesion suite (HEAD `6cd37c8`). Does not replace architecture/memory/roadmap authorities. |
| **[`2026-07-09-design-structure-audit/19-master-playbook.md`](2026-07-09-design-structure-audit/19-master-playbook.md)** | **A** | **Execution entry**: ordered steps A0–F, DS coverage, red lines, progress table. |
| `2026-07-09-design-structure-audit/02-end-to-end-data-flows.md` | A | **Primary evidence**: step-by-step ingest/load/search/select/delete/legacy/images. |
| `2026-07-09-design-structure-audit/17-findings-catalog.md` | A | **DS-001…034** with file:line evidence, impact, verification. |
| `2026-07-09-design-structure-audit/00`–`01`, `03`–`16`, `18`, `glossary` | A | Executive summary, structure map, per-module deep dives, coupling matrix, target shape, glossary. |

### 2026-07-09 — Design audit verification & grilling (A, active)

| Path | role | Summary |
|------|------|---------|
| [`2026-07-09-design-audit-verification/README.md`](2026-07-09-design-audit-verification/README.md) | A | **Verification + recalibration** of the design-structure audit (HEAD `6cd37c8`). 13-agent verify+refute workflow + firsthand grep. |
| [`2026-07-09-design-audit-verification/00-executive-verdict.md`](2026-07-09-design-audit-verification/00-executive-verdict.md) | A | Headline + recalibrated priority order (re-weights playbook Wave A: `NEW-dedup-ids-1` to top; generation bug-class; per-copy O(n)×2 up). |
| [`2026-07-09-design-audit-verification/01-verdict-matrix.md`](2026-07-09-design-audit-verification/01-verdict-matrix.md) | A | Per-finding verdict table (all 34) + adversarial retrial column. |
| [`2026-07-09-design-audit-verification/02-new-findings.md`](2026-07-09-design-audit-verification/02-new-findings.md) | A | **19 issues the audit missed**, ranked Medium→Low. |
| [`2026-07-09-design-audit-verification/03-severity-and-glossary-corrections.md`](2026-07-09-design-audit-verification/03-severity-and-glossary-corrections.md) | A | Severity recalibration rationale + 16 location/glossary fixes. |
| [`2026-07-09-design-audit-verification/glossary-supplement.md`](2026-07-09-design-audit-verification/glossary-supplement.md) | A | Terms sharpened during grilling (search-generation discipline, incremental-but-O(n), silent dedup disable, mutating read, dead-feature subtree). |

> **读法**:`2026-07-09-design-structure-audit/` 的**机制判定**(数据流、DS 定位)经对抗式复核全部成立 → 仍是最准的设计地图;但其**严重度系统性偏高**(6 项夸大),且漏掉 19 项(含静默全去重失效)。**优先级与严重度一律以 `2026-07-09-design-audit-verification/` 为准**;设计机制以原 audit 为准。

### 2026-07-10 — Master roadmap + History-split plan (A, active)

| 路径 | role | 摘要 |
|------|------|------|
| [`2026-07-10-master-roadmap.md`](2026-07-10-master-roadmap.md) | A | **The single forward-looking roadmap** after Wave A: Waves B/C/D/E-F ordered by leverage, deps, decision forks, red lines. Supersedes the playbook's priority order using the verification's recalibration. |
| **[`2026-07-10-history-split-plan/`](2026-07-10-history-split-plan/)** | **A** | **History-structure specialization:** B0 freeze (defer split), hollow-work test, **SwiftLint policy audit** (`a8365fa` 1000/1000), anatomy, DS-022 hollow finding, D4 design (`onEvent` widen), forcing-gate, execution board. **Start here for “what to do about History.swift”.** |
| [`2026-07-10-history-split-plan/00-executive-summary.md`](2026-07-10-history-split-plan/00-executive-summary.md) | A | Locked B0 decisions + anti-patterns + success criteria. |
| [`2026-07-10-history-split-plan/02-swiftlint-policy-audit.md`](2026-07-10-history-split-plan/02-swiftlint-policy-audit.md) | A | Stock vs project length rules; process debt; why lint-only splits are hollow. |
| [`2026-07-10-history-split-plan/06-d4-design.md`](2026-07-10-history-split-plan/06-d4-design.md) | A | D4 measure-first + `onEvent` transport + correctness traps. |
| [`2026-07-10-history-split-plan/08-ordered-execution-plan.md`](2026-07-10-history-split-plan/08-ordered-execution-plan.md) | A | Numbered S0–S7 commits/PRs. |
| [`2026-07-10-history-split-grilling/00-decision.md`](2026-07-10-history-split-grilling/00-decision.md) | A | Short B0 decision seed (adversarial panel). Expanded by `history-split-plan/`. |
| [`2026-07-10-xcodeproj-generation-research.md`](2026-07-10-xcodeproj-generation-research.md) | A | XcodeGen recommendation, current-project parity inventory, pinned generator + zero-diff CI design, migration gates, and test-plan/package/localization traps. |
| [`2026-07-10-xcodeproj-generation-m0-plan.md`](2026-07-10-xcodeproj-generation-m0-plan.md) | A | Completed M0 implementation record: read-only runner capture script/workflow, checked task board, artifact contract, and handoff gate into side-by-side XcodeGen M1. |
| [`2026-07-11-xcodeproj-generation-m1-plan.md`](2026-07-11-xcodeproj-generation-m1-plan.md) | A | Historical completed M1 side-by-side record: pinned/checksummed generator, declarative graph/xcconfigs, semantic parity comparator, and warning-free app build. Superseded operationally by M3. |
| [`2026-07-11-xcodeproj-generation-m2-plan.md`](2026-07-11-xcodeproj-generation-m2-plan.md) | A | Historical completed M2 record: generated-target plan/ID verifier, all five generated-project shards, and Release dry run. Superseded operationally by M3. |
| [`2026-07-11-xcodeproj-generation-m3-plan.md`](2026-07-11-xcodeproj-generation-m3-plan.md) | A | Current production project ownership record: generated output replacement, canonical test-plan refresh, normal CI/release repeatability + zero-drift gates, and full master/release evidence. |
| [`2026-07-12-c5-pin-service-plan.md`](2026-07-12-c5-pin-service-plan.md) | A | C5/DS-015 completion record: context-injected `PinService`, entity boundary cleanup, TDD compile-red, generated-project artifact, and full green matrix/package evidence. |
| [`2026-07-11-c2-signature-index-sync-plan.md`](2026-07-11-c2-signature-index-sync-plan.md) | A | Completed C2.1 TDD record: UI delete/clear batches committed removal events into the actor-owned SignatureIndex; valid red and full green runner evidence; C2.2/C2.3 residual boundaries. |
| [`2026-07-11-c2-signature-reuse-plan.md`](2026-07-11-c2-signature-reuse-plan.md) | A | Completed C2.2 TDD record: one `signatureDTO(of:)` projection now feeds both snapshots and candidate lookup; compile-red and full green runner evidence; C2.3 remains isolated. |
| [`2026-07-11-c2-backfill-transaction-plan.md`](2026-07-11-c2-backfill-transaction-plan.md) | A | Completed C2.3 investigation/fix: refutes the cross-ingest timing using Apple transaction semantics, removes the real read-side mutation, and records forced-transaction-failure/fresh-context green evidence. |
| [`2026-07-11-e1-history-command-service-plan.md`](2026-07-11-e1-history-command-service-plan.md) | A | Completed E1 TDD record: one main-actor Intent port, one 1-based full-history resolver, composition wiring, direct-singleton removal, and runner evidence including the classified `testClear` contention flake. |
| [`2026-07-11-e3-clipboard-timer-plan.md`](2026-07-11-e3-clipboard-timer-plan.md) | A | Completed E3 TDD record: effective interval floor, 10% Timer tolerance, explicit `.common` registration, compile-red, and full green runner evidence. |

### 独立文档

| 路径 | role | 摘要 |
|------|------|------|
| `../keyboard-shortcut-password-fields.md` | A | 用户向排障(密码/secure-input 字段快捷键失灵)。与本审计无关。 |

### 原始捕获数据(永不删除,data)

| 路径 | role | 摘要 |
|------|------|------|
| `../maccy.footprint.txt` | data | 06-27 6h footprint 类别汇总。 |
| `../maccy.heap.txt` | data | 06-27 6h heap dump(按类)。 |
| `../maccy.leaks.txt` | data | 06-27 6h leaks 图(19KB=非泄漏)。 |
| `../maccy.sample.txt` | data | 06-27 6h CPU sample(idle/resident)。 |
| `../maccy.vmmap.full.txt` | data | 06-27 6h 完整 vmmap(框架底证据)。 |
| `../maccy.vmmap.summary.txt` | data | 06-27 6h vmmap 摘要(phys_footprint=135.5MB)。 |

## 3. 阅读约定

- **CI 绿 ≠ spec 完成**:BS-5/6/7/8 均已 commit 且 CI green,但**无一按 spec 完成**(见 06-28 gap-audit)。
- **冻结 spec ≠ 当前状态**:`2026-06-14/roadmap/` 是被测量所依据的 spec-of-record;真实完成度永远以 `2026-06-28-roadmap-bs5-bs8-gap-audit/00-summary.md` 为准,而非步骤文档的 checkbox。
- **架构看单一源**:当前架构/根因以 `architecture-and-root-causes.md` 为参考;不要再引用已删除的 06-14 深度审计或 06-25 模块分析。
- **Design structure (English)**: module boundaries / step data-flows / cohesion-coupling → `2026-07-09-design-structure-audit/`. HEAD re-checks there (fingerprint candidate backfill, DecodedImageCache removed, file-size nil, surrounding guard) **override** stale Chinese draft and outdated gap bullets when they conflict.
- **To refactor step-by-step**: open [`19-master-playbook.md`](2026-07-09-design-structure-audit/19-master-playbook.md) only as the execution entry (do not re-prioritize from scratch).
