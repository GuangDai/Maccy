# 01 — Verdict Matrix (all 34 findings)

**Baseline:** HEAD `6cd37c8` · **Verdict key:** ✅ CONFIRMED · ◐ PARTIALLY · ✗ REFUTED · `△over` severity overstated · `▽under` understated · `⟳` adversarially re-tried (skeptic `agrees=true` unless noted)

| ID | Verdict | Sev (audit→verified) | Conf. | HEAD location | One-line (verified) |
|----|---------|----------------------|-------|---------------|---------------------|
| DS-001 | ✅ `⟳` | High→High | High | `History.swift` 341 LOC + four modules | **Resolved 2026-07-13:** list state, search session, store projector, and mutations own cohesive behavior; `History` is the observable composition facade. |
| DS-002 | ✅ `△over` `⟳` | **Crit→High** | High | `History.swift:420-441` (`try?`@422; loop 425-434) | Fetch-fail → empty set → wipe `all`. **Self-heals on next popup unless store itself is broken** (then `prewarm`'s `load()` also throws & is swallowed). No row deletion. High, not Critical. |
| DS-003 | ✅ `⟳` | High→**Med**¹ | High | `HistoryTestDriver`; deletion `c53a183` | **Resolved:** tests seed the committed store + `StoreEvent` path; legacy `History.add`/sessionLog writer and adapter were deleted. |
| DS-004 | ✅ | High→High | High | `load` 269-285 (bare descriptor @270); loader `Storage+Background.swift:55` | Unbounded fetch; `fetchWindow` has **6 callers, all in `StorageBackgroundContextTests`**. |
| DS-005 | ✅ | desc→desc | High | `CONTEXT.md`; `Dtos.swift`; `SearchActor.swift`; `1393143` | **Sharpened:** stored identity is `PersistentIdentifier.ID`; presentation identity is explicit UUID; signatures/fingerprints remain separately named. |
| DS-006 | ✅ `△over` | High→**Med** | High | 175 occ / 26 files | Structural/testability only; no runtime/correctness impact. (175 vs 171 = occ-vs-lines; also only 4 of 8 singletons counted.) |
| DS-007 | ✅ `⟳` | High→Med-High | High | `HistoryUIEffect`; `acd04dc` | **Resolved:** History modules emit closed value effects; composition-owned `AppState` interprets them. No `History → AppState.shared` sites remain. |
| DS-008 | ✅ `▽under` | Low→**Low (larger)** | High | `Clipboard.swift:315-379,44-61,278-292` | Dead surface **bigger than enumerated**: + `filteredTypes`, `supportedTypes`/`disabledTypes` cascade, `ignoredRegexps` NSCache all dead. |
| DS-009 | ◐ `△over` `⟳` | Med→**Low** | High | `SignatureIndex.swift` (146 LOC); 0 refs in `History.swift` at baseline | Correctness **preserved** at audit time. **Resolved 2026-07-11 (`c6afcbe`):** successful UI delete/clear now batches `.removed`/`.cleared` into the actor index, closing stale growth. |
| DS-010 | ✅ ² `⟳` | Med→Med | High | deletion `5fd7bf4`; `HistorySearchSession` | **Resolved:** empty query publishes the complete list; non-empty modes use `SearchActor`; legacy 217-line engine is deleted. |
| DS-011 | ✅ `⟳` | Med→Med | High | `IngestPolicy` / `IngestMainActorPlan`; `a487276`, `70e1d23` | **Resolved:** `Clipboard` captures live Defaults into the request; ordinary filtering/title/body/limit work stays on the ingest actor. Only planner-selected small RTF/HTML parsing hops to main; fixture-backed routing and the RTF no-trap integration test lock the boundary. |
| DS-012 | ✅ `⟳` | Med→Med | High | `HistorySearchSession.decoratorsByID` | **Resolved:** synchronous UUID lookup makes result projection O(matches), with actor corpus updates serialized before the next search. |
| DS-013 | ✅ `⟳` | Med→Med | High | `HistoryListState.configureWillMutate`; `c7f50be` | **Resolved structurally:** every list/order mutation crosses one invalidation hook; completed-search publication is the intentional non-structural exception. |
| DS-014 | ✅ `⟳` | Med→Med | High | `HistoryStoreProjector.load`; `04ab27c` | **Resolved:** exact unpinned overflow is deleted in one transaction/save and one actor-index synchronization batch. |
| DS-015 | ✅ | Med→Med | High | `PinService.swift`; deletion `76a2a53` | **Resolved:** context-injected `PinService` owns assigned/free pin queries; `HistoryItem` no longer reads `Storage.shared`. |
| DS-016 | ◐ `△over` `⟳` | Med→**Low** | High | deletion `c53a183` | **Resolved:** `MainActorIngestorAdapter` and its legacy conversion/writer path are deleted. |
| DS-017 | ✅ `△over` | Med→**Low** | High | deletion after D1 | **Resolved:** unused `IngestPlan` / `IngestIgnoreReason` and their self-referential Sendable assertion were deleted; the frozen roadmap retains the abandoned design intent. |
| DS-018 | ✅ | Med→Med | High | 8 sites: Get×3, Select×2, Delete×2, Clear×1 | Intents → `AppState.shared`. |
| DS-019 | ✗ `△over` `⟳` | Med→**Low** | High | `StoredItemID`; `1393143` | **Resolved after refutation:** the latent string-format risk is gone; the index directly uses Apple's stable `PersistentIdentifier.ID`, with no schema column. |
| DS-020 | ✅ `⟳` | Med→Med | High | `IngestMailbox`; `b754ac6`, `9fbb6e6` | **Resolved:** one FIFO drain Task serves a burst, with at most one outstanding `ingest`; every observed request is delivered exactly once in order. Latest-wins was rejected as silent clipboard-history data loss. |
| DS-021 | ✅ | Med→Med | Med | `History.swift:383` | `model.title == snapshot.title` gate → full reconcile on mismatch. |
| DS-022 | ✅ `⟳` | Med→Med | High | `HistoryStoreProjector` → `HistoryPersistence`; `b8da02f` | **Resolved:** load/model lookup/reconcile and mutations use the injected port; direct `ModelContext` IO is confined to `SwiftDataHistoryPersistence`. |
| DS-023 | ✅ `⟳` | Med→Med | High | `loadAndRecordError`; fake-backed projector test | **Resolved:** popup/prewarm paths record failures; the final test-only force flag was removed after fake persistence covered the seam. |
| DS-024 | ✅ `⟳` | Med→Med | High | `Clipboard.start` Timer | **Resolved `32320cf`:** tested 10% tolerance; explicit main-run-loop `.common` registration. |
| DS-025 | ◐ `△over` `⟳` | Med→**Low** | High | `HistoryPersistence.deleteUnpinned` | **Resolved:** a new integration test proved pending unpinned inserts survived predicate deletion (red run `29182928718`); the persistence port now commits pending main-context edits before the batch predicate delete while preserving pending pinned rows (green run `29183054806`). |
| DS-026 | ✅ | Med→Med | High | E2 `2a06a58`/`72fa8f2`/`9e54d77` | **Resolved:** root Swift 29→22; composition and test/perf hooks left `AppDelegate` for `Application/` modules. |
| DS-027 | ✅ | Med→Med | High | README re-checks | All 4 HEAD re-checks accurate (fingerprint candidate-only; `dataFromFileIfAllowed` nil-on-fail; `DecodedImageCache` gone; `item(before:)` guarded). |
| DS-028 | ✅ `▽under` `⟳` | Low/Med→**High (cleanup)** | High | deletion `9849d00` | **Resolved:** the ~250 LOC dead paste-stack/multi-select subtree and always-false gate were deleted. |
| DS-029 | ✅ `△over` `⟳` | Med→**Low** | High | `HistorySearchSession.corpusUpdateTask` | **Resolved with B2/C3:** lookup updates synchronously and actor corpus operations serialize ahead of the next search. |
| DS-030 | ✅ | Med→Med | High | `HistoryItemEngine` | **Resolved:** all engine APIs consume `[ContentDTO]`; ingest projects title/search directly from request values and no longer builds throwaway SwiftData models. |
| DS-031 | ◐ | Low→Low | High | deletion after D1 | **Resolved with DS-017:** the unused plan/reason DTOs were deleted rather than promoted into the live actor pipeline. |
| DS-032 | ✅ | Low→Low | High | `Application/DebugHooks.swift`; `72fa8f2` | **Resolved:** whole-file DEBUG module owns the test/perf bridge; `AppDelegate` only forwards lifecycle calls under `#if DEBUG`. |
| DS-033 | ◐ | Low→Low | High | `StorageSettingsPane.swift:70,121` only | Only **one** pane reads `Storage.shared` in prod (Pins pane hit is `#Preview`). |
| DS-034 | ✅ | Low→Low | High | `Maccy/Search/`; `2a06a58` | **Resolved:** all four search sources are colocated with zero source changes. |

**Adversarial retrial column** (6 correctness-critical findings, skeptic re-read the code and argued the opposite):

| ID | Cluster verdict | Adversarial final | Skeptic's killer detail |
|----|----------------|-------------------|-------------------------|
| DS-002 | CONFIRMED / High | **CONFIRMED / High** (agrees) | `fetchIdentifiers` is documented `throws`; self-heal fails precisely when the store is broken → silent masking, not recovery. Critical not warranted (no data destruction). |
| DS-003 | CONFIRMED / High | **CONFIRMED / Medium** (agrees)¹ | No live dual-write — legacy path reachable only via the never-instantiated adapter. Mechanism forced; only the High-vs-Medium tier was arguable. |
| DS-009 | PARTIALLY / Low | **PARTIALLY / High-conf** (agrees) | `supersedes`=containment over `self.contents` → empty shell structurally cannot match; shared-store delete propagation. "No false-positive ever" leans on empirical SwiftData behavior, not a formal guarantee. |
| DS-013 | CONFIRMED / Medium | **CONFIRMED / Medium** (agrees) | Only gen-writers are `performSearch`@861 & `invalidate`@949; togglePin omits it while `clear`/`clearAll`/`delete` all call it. |
| DS-019 | REFUTED / Low | **REFUTED / High-conf** (agrees) | Original cross-launch failure remained refuted; `1393143` subsequently removed even the latent description dependency by using `PersistentIdentifier.ID`. |
| DS-025 | PARTIALLY / Low | **PARTIALLY / Medium-conf** (agrees) | Sole main-context insert (`History.swift:36`) saves immediately @37-38; actor uses a separate context. No live pending-insert path. |

¹ DS-003 severity: the cluster verifier held High; the adversarial skeptic downgraded to Medium with a strong argument (no live dual-write). The skeptic's Medium is adopted as the verified severity.

² DS-010: the `verify:search` workflow agent failed with a transient rate limit (429); the finding was verified firsthand by the author (legacy `Search.swift` = 217 LOC, empty-query path calls `search.search("", within: all)` at `History.swift:855`).

---

## Tally

- **Confirmed as-is:** 25 · **Partially confirmed:** 5 · **Refuted:** 1 (DS-019)
- **Severity overstated:** 6 (DS-002, 006, 016, 017, 019, 025) + DS-029 · **Understated:** 2 (DS-008, 028)
- **Adversarial pass:** 6/6 skeptics agreed with the verifier after attempting refutation.
- **Measurement accuracy:** every figure the author checked firsthand landed exactly (989, 23, 171→175 occ/26 files, 217, 29, 6).
