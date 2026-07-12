# 17 — Findings Catalog (DS-xxx) with Evidence

**Baseline:** HEAD `6cd37c8`  
Every finding: **severity · location · evidence · mechanism · impact · recommendation · verification · confidence**.

---

## Critical

### DS-002 — `syncAllToStore` maps fetch failure to empty store

| | |
|--|--|
| **Severity** | Critical |
| **Location** | `Maccy/Observables/History.swift` `syncAllToStore` |
| **Evidence** | ```420:433:Maccy/Observables/History.swift``` — `(try? fetchIdentifiers(...)) ?? []` then remove every decorator not in set |
| **Mechanism** | On throw, `storeIDs` is empty → loop deletes **all** in-memory decorators and schedules corpus removes |
| **Impact** | User sees empty history; SQLite may still hold rows; recovery only via reload if load still works |
| **Confusion** | Legitimate empty DB after clearAll is the same branch as failure |
| **Recommendation** | On fetch error: set `lastPersistError`, **return without mutating `all`**. Distinguish empty success |
| **Verification** | Fault-inject `fetchIdentifiers` to throw; assert `all` unchanged; assert error recorded |
| **Confidence** | **High** (static path closed); Medium that throw is common in prod |

---

## High

### DS-001 — `History` god object (~989 LOC)

> **Resolved 2026-07-13:** `History.swift` is now a 341-line observable
> composition facade. `HistoryListState`, `HistorySearchSession`,
> `HistoryStoreProjector`, and `HistoryMutations` own the four high-change
> clusters; the legacy writer was deleted instead of extracted.

| | |
|--|--|
| **Location** | `Maccy/Observables/History.swift` |
| **Evidence** | Single type owns: persistence protocol + load + legacy add + consume/reconcile + search session + delete/clear/pin/select + shortcuts + Defaults listeners + 23 AppState side effects |
| **Method inventory** | `load`, `add`, `consume`, `insertIncrementally`, `syncAllToStore`, `reconcileWithStore`, `clear`, `clearAll`, `delete`, `select`, `togglePin`, `findSimilarItem`, `performSearch`, `applySearchResults`, … (see grep of `func` in file — ~40 methods) |
| **Impact** | Any feature change risks unrelated regressions; review/test cost max |
| **Recommendation** | Facade + file/type split: ListState, StoreProjector, SearchSession, Mutations, LegacyWriter; see playbook Wave B |
| **Confidence** | High |

### DS-003 — Dual write paths (live actor vs legacy `add`)

> **Resolved (`887b2c8`…`c53a183`):** tests seed committed models through
> `HistoryTestDriver` and consume `StoreEvent`s; the legacy add/sessionLog writer
> and `MainActorIngestorAdapter` were deleted.

| | |
|--|--|
| **Production** | AppDelegate → `BackgroundClipboardIngestor` → `consume` only |
| **Legacy** | `History.add` + `findSimilarItem` + `sessionLog` + multi-save style |
| **Evidence (prod)** | `AppDelegate.swift` 82–88 |
| **Evidence (legacy still present)** | `History.add` 308+; `findSimilarItem` 742+; `sessionLog` 182 |
| **Evidence (tests)** | Widespread `history.add(...)` in `HistoryTests`, `HistoryPinPersistenceTests`, `PopupTests`, `PerfHistoryFactory`, … |
| **Evidence (adapter)** | `MainActorIngestorAdapter` calls `History.shared.add` and returns **nil event** |
| **Semantic deltas** | sessionLog modification-merge only on legacy; single txn only on actor; adapter skips StoreEvent |
| **Impact** | Cannot treat add as dead; tests train wrong production path |
| **Recommendation** | Map callers (Wave A2); migrate tests to consume/seed helper; isolate/remove legacy |
| **Confidence** | High |

### DS-004 — Full-table `load` + unwired `VisibleWindowLoader`

| | |
|--|--|
| **Evidence load** | `History.load` uses `FetchDescriptor<HistoryItem>()` with no limit (`History.swift` 269–271) |
| **Evidence loader** | `VisibleWindowLoader.fetchWindow` in `Storage+Background.swift` 49+; comment “not yet wired”; only `StorageBackgroundContextTests` |
| **Impact** | Main-thread sort/decorate all rows; mainContext retention (memory suite); dual APIs |
| **Recommendation** | Written ADR: wire vs delete; implement only after ADR |
| **Confidence** | High |

### DS-005 — Three IDs + two signatures

| | |
|--|--|
| **Evidence** | `CONTEXT.md`; `HistoryItemDecorator.id = UUID()`; `StoredItemID = PersistentIdentifier.ID`; Engine.Signature vs SignatureDTO |
| **Impact** | Merge must re-key search corpus by presentation id; stored vs presentation identity and signature vs fingerprint must remain distinct. |
| **Recommendation** | **Completed (`1393143`):** canonical glossary + invariant test + direct stable stored identity; search actor explicitly uses presentation UUID. |
| **Confidence** | High |

### DS-006 — Global singleton bus

| | |
|--|--|
| **Evidence** | 171 matches of main `*.shared` patterns across 26 production files |
| **Impact** | Hidden deps; hard isolation tests; any module can mutate global session |
| **Recommendation** | Stop new shared call sites; inject at boundaries; progressive |
| **Confidence** | High |

### DS-007 — `History` → `AppState.shared` bidirectional control coupling

> **Resolved (`acd04dc`):** History modules emit `HistoryUIEffect` values through
> a composition-owned sink. `AppState` interprets the values; no History module
> imports or reaches through `AppState.shared`.

| | |
|--|--|
| **Evidence** | **23** lines in `History.swift` alone: popup.needsResize/close, navigator.select/highlight/scrollTarget (rg `AppState.shared` on file) |
| **Reverse** | AppState holds History; Views bind AppState.shared |
| **Impact** | Cannot unit-test projection without UI chrome; cycles |
| **Recommendation** | `UIEffectPort` / callbacks injected into History |
| **Confidence** | High |

### DS-008 — Dual filter configuration + dead Clipboard helpers

| | |
|--|--|
| **Dead helpers** | `shouldIgnore(_ item:)`, `isEmptyString`, `richText` — definitions only at Clipboard.swift 315–379; call sites only type/app overloads 221–227 |
| **Dual config** | `Clipboard` private supported/ignored sets vs `BackgroundClipboardIngestor.ingestConfig()` hardcoded raw UTI strings 445–466 |
| **Regex** | Actor path recompiles patterns each filter; Clipboard had NSCache path only on dead helper |
| **Impact** | Drift when one side updates types; noise |
| **Recommendation** | Single shared constants; delete dead helpers |
| **Confidence** | High |

### DS-009 — UI mutations do not update actor SignatureIndex

| | |
|--|--|
| **Evidence** | Index maintained only inside actor: `ensureDedupIndexInitialized`, `maintainDedupIndex` after commit. `History.delete`/`clear` update arrays + search corpus only |
| **Impact** | Stale stored item identities in index; extra candidates; relies on supersedes false / empty shells |
| **Recommendation** | `noteRemoved` on actor or dirty-rebuild; ideally unified events |
| **Confidence** | High mechanism; Medium severity in practice (correctness mostly held by supersedes) |

---

## Medium

### DS-010 — Dual search engines

> **Resolved (`27562cc`, `5fd7bf4`; full matrix `29205361439`):**
> `HistorySearchSession` owns the actor path and empty-query publication; the
> legacy engine and its duplicate test oracle are deleted.

| | |
|--|--|
| **Evidence** | Empty query: `search.search("", within: all)` (`History.performSearch` ~851–855). Non-empty: `searchActor.search`. `Search` class still full 4-mode engine (~217 LOC) |
| **Impact** | Behavior drift; two test oracles |
| **Recommendation** | MatchEngine shared; empty query short-circuit without legacy class |
| **Confidence** | High |

### DS-011 — Ingest MainActor hop for filter/title/body

> **Resolved 2026-07-12 (`a487276`, `70e1d23`):** `Clipboard` captures a
> Sendable `IngestPolicy` with each request. A pure `IngestMainActorPlan` keeps
> file/plain/image filtering and projection on the ingest actor and routes only
> selected small RTF/HTML parsing to main. Fixture-backed heavy-text/RTF tests
> plus the existing no-trap integration test guard the split.

| | |
|--|--|
| **Evidence** | `ClipboardIngestor.ingest` `MainActor.run` block 161–172 |
| **Impact** | Copy-path main-thread latency (metrics `parseMs`) |
| **Recommendation** | Snapshot Defaults off hot path; evaluate off-main rich text with fixtures |
| **Confidence** | High |

### DS-012 — O(n) decorator resolve in `applySearchResults`

> **Resolved (`27562cc`):** the session maintains an O(1)
> `[UUID: HistoryItemDecorator]` lookup synchronized with its corpus.

| | |
|--|--|
| **Evidence** | `all.first(where: { $0.id == dto.id })` in apply loop (`History.swift` ~900) |
| **Impact** | O(matches × n) per keystroke |
| **Recommendation** | Maintain `[UUID: HistoryItemDecorator]` |
| **Confidence** | High |

### DS-013 — `togglePin` does not invalidate in-flight search

> **Resolved structurally (`c7f50be`):** all structural list mutations pass
> through `HistoryListState`'s single invalidation hook.

| | |
|--|--|
| **Evidence** | `togglePin` updates corpus position but no `invalidateInFlightSearch` / `performSearch` |
| **Impact** | Brief wrong order/highlight under concurrent search |
| **Recommendation** | Bump generation; re-run search if query non-empty |
| **Confidence** | Medium |

### DS-014 — `limitHistorySize` deletes one-by-one

> **Resolved (`04ab27c`; full matrix `29206774668`):** the projector sends the
> exact overflow to one persistence transaction/save and one index-sync batch.

| | |
|--|--|
| **Evidence** | `unpinned[maxSize...].forEach(delete)` (`History.swift` 288–293); each `delete` saves |
| **Impact** | Write amplification on load/add |
| **Recommendation** | Single transaction batch delete |
| **Note** | Actor trim already batches in one txn — UI path weaker |
| **Confidence** | High |

### DS-015 — `HistoryItem.availablePins` queries `Storage.shared` — RESOLVED (`76a2a53`, `b49b462`)

| | |
|--|--|
| **Evidence** | Historical: `HistoryItem.swift` ~52–66 fetched `pin != nil` on `Storage.shared.context`. Current: `PinService(context:)` owns the query and `HistoryItem` has no pin-query/static allocation surface. |
| **Impact** | Domain entity tied to infrastructure + main actor |
| **Recommendation** | PinService / Mutations with injected context |
| **Resolution** | `PinService` receives the caller's `ModelContext`; settings use their environment context and decorators receive the module through their initializer. Full generated-project matrix + Release package passed in `29154584664`. |
| **Confidence** | High |

### DS-016 — `MainActorIngestorAdapter` residual

> **Resolved (`c53a183`):** the adapter and legacy writer were deleted after
> test migration proved replacement coverage.

| | |
|--|--|
| **Evidence** | `ClipboardIngestor.swift` 14–36; production sets Background* only |
| **Impact** | Mis-wiring risk; nil-event semantics |
| **Recommendation** | Test target only |
| **Confidence** | High |

### DS-017 — `IngestPlan` unused for decisions

> **Resolved 2026-07-12:** `IngestPlan` and `IngestIgnoreReason` had no live
> producer or consumer; their only external reference asserted Sendable
> conformance. The types and that assertion were deleted. The frozen roadmap
> remains the record of the abandoned design intent.

| | |
|--|--|
| **Evidence** | Defined `Dtos.swift` 110+; only `DtoTests.requireSendable(IngestPlan.self)` |
| **Impact** | Fake pipeline abstraction |
| **Recommendation** | **Completed:** deleted; the existing direct actor pipeline remains the single implementation. |
| **Confidence** | High |

### DS-018 — App Intents hit `AppState.shared`

> **Resolved 2026-07-11 (`cd368ea`):** App Intents now depend on the main-actor `HistoryCommandService` port configured at composition time. No `AppState.shared` reference remains under `Maccy/Intents`.

| | |
|--|--|
| **Evidence** | `Intents/Get.swift`, `Select.swift`, `Delete.swift`, `Clear.swift` |
| **Impact** | No application port; hard to test intents |
| **Recommendation** | `HistoryCommandService` protocol |
| **Confidence** | High |

### DS-019 — ItemID depends on `String(describing: PersistentIdentifier)` — RESOLVED (`1393143`)

| | |
|--|--|
| **Evidence** | Historical: `Dtos.swift` `itemID(for:)` hashed `String(describing:)`. Current: `StoredItemID = PersistentIdentifier.ID`; committed snapshot identity is characterized directly. |
| **Impact** | Original cross-relaunch failure was refuted because the index rebuilt each process; the remaining undocumented-format and collision risks are now removed. |
| **Recommendation** | **Completed:** use Apple's stable store-scoped ID; no redundant UUID column/migration. |
| **Confidence** | Medium (risk), High (mechanism) |

### DS-020 — No ingest coalesce

> **Resolved 2026-07-12 (`b754ac6`, `9fbb6e6`):** `IngestMailbox` uses one
> FIFO drain Task per burst and permits only one outstanding ingest. It retains
> every observed request in order; latest-wins was rejected because dropping an
> already-snapshotted copy violates clipboard-history semantics.

| | |
|--|--|
| **Evidence** | Each changeCount → new `Task { await ingest }` |
| **Impact** | Copy storms queue full pipelines |
| **Recommendation** | Product decision + mailbox/serial latest |
| **Confidence** | High |

### DS-021 — Title equality gate may over-reconcile

| | |
|--|--|
| **Evidence** | `insertIncrementally` requires `model.title == snapshot.title` |
| **Impact** | Any title mismatch forces full table fetch/sort (perf); if shell empty title, always reconcile |
| **Recommendation** | Prefer persistentID + isDeleted checks; document title as soft signal |
| **Confidence** | Medium |

### DS-022 — Persistence dual channel on History

> **Resolved (`b8da02f`):** `HistoryStoreProjector` and `HistoryMutations` use
> injected `HistoryPersistence`; only `SwiftDataHistoryPersistence` touches the
> main `ModelContext`. Fake-backed load/model-miss/reconcile tests lock the seam.

| | |
|--|--|
| **Evidence** | `persistence` for delete/insert; **also** direct `Storage.shared.context` in load/reconcile/syncAll/mergeDuplicate |
| **Impact** | Injected persistence cannot fully isolate History in tests for load path |
| **Recommendation** | All store IO through one port |
| **Confidence** | High |

### DS-023 — Load / prewarm swallow errors

> **Resolved:** callers route through `loadAndRecordError`; fake persistence
> proves fetch failure preserves the old projection and records the error. The
> obsolete DEBUG force-failure flag was removed in the final facade cleanup.

| | |
|--|--|
| **Evidence** | `ContentView` `try? await load`; `AppState.prewarmVisibleWindow` `try?` |
| **Impact** | Silent empty UI on load failure |
| **Recommendation** | Surface `lastPersistError` / user-visible failure |
| **Confidence** | High |

### DS-024 — Timer without tolerance / common mode

> **Resolved 2026-07-11 (`32320cf`):** `Clipboard.start()` now applies a tested 10% tolerance to the effective polling interval and explicitly registers the Timer on the main run loop in `.common` mode.

| | |
|--|--|
| **Evidence** | `Clipboard.start` Timer API |
| **Impact** | Delayed capture under UI tracking |
| **Recommendation** | tolerance + `.common` mode |
| **Confidence** | Medium |

### DS-025 — `deleteUnpinned` pending-vs-saved risk (SwiftData)

> **Resolved 2026-07-12:** the previously dormant mechanism was reproduced:
> an unsaved unpinned insert survived the predicate delete (red run
> `29182928718`), while a pending pinned control row also remained. The port now
> saves only when the main context has pending edits before issuing the batch
> delete; the integration test passes in run `29183054806`.

| | |
|--|--|
| **Evidence** | `SwiftDataHistoryPersistence.deleteUnpinned` uses predicate delete in transaction then save; architecture docs note predicate delete vs pending asymmetry |
| **Impact** | If pending inserts unpinned exist, predicate may not match expectations |
| **Recommendation** | **Completed:** explicit pending-save discipline plus pinned/unpinned integration coverage. |
| **Confidence** | Medium |

### DS-026 — Root Swift surface area / AppDelegate overload — RESOLVED (`2a06a58`, `72fa8f2`, `9e54d77`)

| | |
|--|--|
| **Evidence** | Historical: ~29 root-level Swift files; AppDelegate wired ingest, status item, Defaults migration, and UITest/Perf hooks. Current: 22 root Swift files; `Application/CompositionRoot` owns infrastructure wiring and `Application/DebugHooks` owns the test/perf bridge. |
| **Impact** | Navigation cost; composition mixed with tests |
| **Recommendation** | CompositionRoot + DebugHooks split; later package moves |
| **Resolution** | `AppDelegate`/`MaccyApp` plus both extracted modules live under `Application/`; `AppDelegate` is 209 lines and retains delegate/status-window responsibilities. Generated Release + all test shards passed in `29167115880`. |
| **Confidence** | High |

### DS-027 — Documentation drift vs HEAD

| | |
|--|--|
| **Evidence** | Older gap audit vs this suite (fingerprint, DecodedImageCache, file read, surrounding) |
| **Impact** | Engineers fix already-fixed bugs or miss real ones |
| **Recommendation** | Keep INDEX pointing here for structure; update architecture cross-links |
| **Confidence** | High |

### DS-028 — `multiSelectionEnabled = false` dead switch

> **Resolved 2026-07-10 (`9849d00`):** the unreachable paste-stack/multi-select model, views, state, and key-handling branches were deleted rather than retaining an always-false feature gate.

| | |
|--|--|
| **Evidence** | `AppState.nonisolated let multiSelectionEnabled = false` |
| **Impact** | Dead product surface / incomplete feature |
| **Recommendation** | Finish or remove branches |
| **Confidence** | Medium |

### DS-029 — Fire-and-forget corpus Tasks race

| | |
|--|--|
| **Evidence** | insertIncrementally / syncAll / pin use unstructured `Task { await actor… }` without generation coupling to those updates |
| **Impact** | Search can run on corpus missing latest item (documented “one item stale”) |
| **Recommendation** | Accept with tests; or await corpus update before allowing search apply for destructive ops |
| **Confidence** | High mechanism; Medium user impact |

### DS-030 — Engine still takes `[HistoryItemContent]` (@Model types)

> **Resolved 2026-07-12:** every `HistoryItemEngine` entry point now consumes
> `[ContentDTO]`. The ingest actor sends its existing request values directly;
> `HistoryItem` projects persistence contents at its boundary. Title/search
> projection no longer creates throwaway `@Model` objects.

| | |
|--|--|
| **Evidence** | `HistoryItemEngine` APIs take `HistoryItemContent` arrays; ingest builds throwaway models for title |
| **Impact** | Domain “pure” layer still coupled to persistence type |
| **Recommendation** | **Completed:** accept `ContentDTO`; persistence models stay outside the engine. |
| **Confidence** | High |

---

## Low / hygiene

| ID | Summary | Confidence |
|----|---------|------------|
| DS-031 | **Resolved with DS-017:** unused plan/reason DTO surface deleted | High |
| DS-032 | **Resolved (`72fa8f2`):** whole-file DEBUG `Application/DebugHooks.swift` | High |
| DS-033 | Settings panes read Storage.shared directly | High |
| DS-034 | **Resolved (`2a06a58`):** all four sources under `Maccy/Search/` | High |

---

## Dead / half-wired symbol table

| Symbol | Kind | Evidence | Risk if deleted |
|--------|------|----------|-----------------|
| `History.add` family | Prod-dead / test-live | AppDelegate unused; tests heavy | Breaks test suite |
| `Clipboard.shouldIgnore(item)`, `isEmptyString`, `richText` | Dead | No call sites | Low |
| `VisibleWindowLoader` | **Deleted after D1 no-go** | Was tests only | — |
| `MainActorIngestorAdapter` | Residual | Not set in AppDelegate | Low if tests updated |
| `IngestPlan` | **Deleted** | Was Sendable-test only | — |
| `sessionLog` | Legacy-only | Used by add/isModified | Medium for legacy tests |

---

## Cross-reference to older finding IDs

| DS | Older IDs |
|----|-----------|
| DS-002 | (new) |
| DS-004 | load-no-pipeline-offload |
| DS-008 | filter duplication |
| DS-011 | richtext-sync-decode-on-ingest |
| DS-003 | findsimilar-full-refetch (now dead in prod) |
| DS-009 | (new structural) |
| DS-025 | 07-F-014 class |

---

## Severity × difficulty matrix (planning)

```text
Correctness first:  DS-002, DS-013, DS-025, DS-023
Structure spine:    DS-001, DS-003, DS-007, DS-022
Domain consistency: DS-005, DS-008, DS-009, DS-010, DS-015, DS-019, DS-030
Read/perf paths:    DS-004, DS-011, DS-012, DS-014, DS-020, DS-021
Hygiene:            DS-016–018, DS-024, DS-026–028, DS-031–034
```
