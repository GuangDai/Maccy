# 01 — Verdict Matrix (all 34 findings)

**Baseline:** HEAD `6cd37c8` · **Verdict key:** ✅ CONFIRMED · ◐ PARTIALLY · ✗ REFUTED · `△over` severity overstated · `▽under` understated · `⟳` adversarially re-tried (skeptic `agrees=true` unless noted)

| ID | Verdict | Sev (audit→verified) | Conf. | HEAD location | One-line (verified) |
|----|---------|----------------------|-------|---------------|---------------------|
| DS-001 | ✅ | High→High | High | `History.swift:96-984` (file 989 LOC) | God object: 37 `func` in the class, 15 responsibilities, 23 `AppState.shared` sites. Exact. |
| DS-002 | ✅ `△over` `⟳` | **Crit→High** | High | `History.swift:420-441` (`try?`@422; loop 425-434) | Fetch-fail → empty set → wipe `all`. **Self-heals on next popup unless store itself is broken** (then `prewarm`'s `load()` also throws & is swallowed). No row deletion. High, not Critical. |
| DS-003 | ✅ `⟳` | High→**Med**¹ | High | prod wire `AppDelegate.swift:82`; legacy `History.swift:308/742/182` | Dual paths real; but legacy reachable in prod **only via `MainActorIngestorAdapter.ingest` (0 instantiation sites)** → no live dual-write/race. `ClipboardIngestor.swift:44-46` doc still calls adapter "the runtime path" (false). |
| DS-004 | ✅ | High→High | High | `load` 269-285 (bare descriptor @270); loader `Storage+Background.swift:55` | Unbounded fetch; `fetchWindow` has **6 callers, all in `StorageBackgroundContextTests`**. |
| DS-005 | ✅ | desc→desc | High | `Dtos.swift:178-180`, `186-217` | 3 IDs + 2 signatures, accurate. (See `03`: fold is at 186-217, not 177-180.) |
| DS-006 | ✅ `△over` | High→**Med** | High | 175 occ / 26 files | Structural/testability only; no runtime/correctness impact. (175 vs 171 = occ-vs-lines; also only 4 of 8 singletons counted.) |
| DS-007 | ✅ | High→Med-High | High | 23 sites (lines listed in `03`) | Central spine coupling; no runtime impact. Exact count. |
| DS-008 | ✅ `▽under` | Low→**Low (larger)** | High | `Clipboard.swift:315-379,44-61,278-292` | Dead surface **bigger than enumerated**: + `filteredTypes`, `supportedTypes`/`disabledTypes` cascade, `ignoredRegexps` NSCache all dead. |
| DS-009 | ◐ `△over` `⟳` | Med→**Low** | High | `SignatureIndex.swift` (146 LOC); 0 refs in `History.swift` at baseline | Correctness **preserved** at audit time. **Resolved 2026-07-11 (`c6afcbe`):** successful UI delete/clear now batches `.removed`/`.cleared` into the actor index, closing stale growth. |
| DS-010 | ✅ ² | Med→Med | High | legacy `Search.swift` (217 LOC); `History.swift:855` | Empty query → `search.search("")`; non-empty → `SearchActor`. Confirmed firsthand (cluster agent rate-limited). |
| DS-011 | ✅ | Med→Med | High | `ClipboardIngestor.swift:161-172` | `MainActor.run` for config+filter+title+body+limit. |
| DS-012 | ✅ | Med→Med | High | `History.swift:900` | `all.first { $0.id == dto.id }` O(n) per match → O(matches×n)/keystroke. |
| DS-013 | ✅ `⟳` | Med→Med | High | `togglePin` 702-738 | No `invalidateInFlightSearch`/gen bump. Fix = one `invalidateInFlightSearch()` (query is cleared @733; nothing to re-run). **Part of a bug class** — see `00` §2.2. |
| DS-014 | ✅ | Med→Med | High | `limitHistorySize` 288-294 (delete@292) | Per-item `delete`+save; actor trims batch in one txn. |
| DS-015 | ✅ | Med→Med | High | `HistoryItem.swift:52-66` (fetch @59) | `availablePins` reads `Storage.shared.context`. |
| DS-016 | ◐ `△over` | Med→**Low** | High | `ClipboardIngestor.swift:14-37` | Not "residual" — **fully dead**: 0 instantiation sites; only static `historyItem(from:)` used in 1 test. |
| DS-017 | ✅ `△over` | Med→**Low** | High | `Dtos.swift:110` + `DtoTests.swift:17` | Nominal; only `requireSendable` references it. |
| DS-018 | ✅ | Med→Med | High | 8 sites: Get×3, Select×2, Delete×2, Clear×1 | Intents → `AppState.shared`. |
| DS-019 | ✗ `△over` `⟳` | Med→**Low** | High | `Dtos.swift:178-180`→`186-217` | **Refuted as cross-relaunch risk**: ItemID **not persisted** in any `@Model`; index rebuilt from store on first ingest every process → format change absorbed. Only latent reliance on undocumented format. |
| DS-020 | ✅ | Med→Med | High | `Clipboard.swift:237` | One `Task` per changeCount; no coalesce. |
| DS-021 | ✅ | Med→Med | Med | `History.swift:383` | `model.title == snapshot.title` gate → full reconcile on mismatch. |
| DS-022 | ✅ | Med→Med | High | `History.swift` load/reconcile/syncAll/merge | Dual IO channel; fake `HistoryPersistence` can't intercept load. |
| DS-023 | ✅ | Med→Med | High | `ContentView` `try?`; `AppState:101` `try?` | Load errors swallowed. |
| DS-024 | ✅ `⟳` | Med→Med | High | `Clipboard.start` Timer | **Resolved `32320cf`:** tested 10% tolerance; explicit main-run-loop `.common` registration. |
| DS-025 | ◐ `△over` `⟳` | Med→**Low** | Med | `History.swift:49-62` (**inline**, not a separate file) | No-save-before-predicate real, but **no prod path leaves a pending main-context insert**; trigger dormant. |
| DS-026 | ✅ | Med→Med | High | 29 root `.swift`; `AppDelegate` 390 (≈110 DEBUG) | Overload. Exact. |
| DS-027 | ✅ | Med→Med | High | README re-checks | All 4 HEAD re-checks accurate (fingerprint candidate-only; `dataFromFileIfAllowed` nil-on-fail; `DecodedImageCache` gone; `item(before:)` guarded). |
| DS-028 | ✅ `▽under` `⟳` | Low/Med→**High (cleanup)** | High | deletion `9849d00` | **Resolved:** the ~250 LOC dead paste-stack/multi-select subtree and always-false gate were deleted. |
| DS-029 | ✅ `△over` | Med→**Low** | High | fire-and-forget corpus `Task`s | One-item lag; documented; self-correcting. |
| DS-030 | ✅ | Med→Med | High | `HistoryItemEngine` | Takes `[HistoryItemContent]` (@Model). |
| DS-031 | ◐ | Low→Low | High | `Dtos.swift` | `IngestPlan`/`IngestIgnoreReason` unused (overlaps DS-017). |
| DS-032 | ✅ | Low→Low | High | `AppDelegate` ≈110 LOC `#if DEBUG` | DEBUG-gated; no shipped bloat. |
| DS-033 | ◐ | Low→Low | High | `StorageSettingsPane.swift:70,121` only | Only **one** pane reads `Storage.shared` in prod (Pins pane hit is `#Preview`). |
| DS-034 | ✅ | Low→Low | High | `Search*.swift` at root | Not colocated under `Search/`. |

**Adversarial retrial column** (6 correctness-critical findings, skeptic re-read the code and argued the opposite):

| ID | Cluster verdict | Adversarial final | Skeptic's killer detail |
|----|----------------|-------------------|-------------------------|
| DS-002 | CONFIRMED / High | **CONFIRMED / High** (agrees) | `fetchIdentifiers` is documented `throws`; self-heal fails precisely when the store is broken → silent masking, not recovery. Critical not warranted (no data destruction). |
| DS-003 | CONFIRMED / High | **CONFIRMED / Medium** (agrees)¹ | No live dual-write — legacy path reachable only via the never-instantiated adapter. Mechanism forced; only the High-vs-Medium tier was arguable. |
| DS-009 | PARTIALLY / Low | **PARTIALLY / High-conf** (agrees) | `supersedes`=containment over `self.contents` → empty shell structurally cannot match; shared-store delete propagation. "No false-positive ever" leans on empirical SwiftData behavior, not a formal guarantee. |
| DS-013 | CONFIRMED / Medium | **CONFIRMED / Medium** (agrees) | Only gen-writers are `performSearch`@861 & `invalidate`@949; togglePin omits it while `clear`/`clearAll`/`delete` all call it. |
| DS-019 | REFUTED / Low | **REFUTED / High-conf** (agrees) | Neither `@Model` stores an ItemID; `ensureDedupIndexInitialized` re-derives all keys on first ingest every process. |
| DS-025 | PARTIALLY / Low | **PARTIALLY / Medium-conf** (agrees) | Sole main-context insert (`History.swift:36`) saves immediately @37-38; actor uses a separate context. No live pending-insert path. |

¹ DS-003 severity: the cluster verifier held High; the adversarial skeptic downgraded to Medium with a strong argument (no live dual-write). The skeptic's Medium is adopted as the verified severity.

² DS-010: the `verify:search` workflow agent failed with a transient rate limit (429); the finding was verified firsthand by the author (legacy `Search.swift` = 217 LOC, empty-query path calls `search.search("", within: all)` at `History.swift:855`).

---

## Tally

- **Confirmed as-is:** 25 · **Partially confirmed:** 5 · **Refuted:** 1 (DS-019)
- **Severity overstated:** 6 (DS-002, 006, 016, 017, 019, 025) + DS-029 · **Understated:** 2 (DS-008, 028)
- **Adversarial pass:** 6/6 skeptics agreed with the verifier after attempting refutation.
- **Measurement accuracy:** every figure the author checked firsthand landed exactly (989, 23, 171→175 occ/26 files, 217, 29, 6).
