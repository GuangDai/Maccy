# 02 — New Findings (what the audit missed)

**Baseline:** HEAD `6cd37c8` · **Source:** surfaced by the 7 verification clusters while reading source; mechanisms re-stated from HEAD. **19 issues**, ranked Medium → Low. The top item (`NEW-dedup-ids-1`) is, on reflection, more serious than most of the audit's "High" findings.

Severity convention matches the design audit: **Medium** = real defect worth scheduling; **Low** = hygiene/latent/dormant-trigger.

---

## Medium

### `NEW-dedup-ids-1` — silent session-wide dedup disable on first-ingest fetch failure

| | |
|--|--|
| **Location** | `Maccy/Ingest/ClipboardIngestor.swift:346-353` (`ensureDedupIndexInitialized`) |
| **Mechanism** | `(try? modelContext.fetch(FetchDescriptor<HistoryItem>())) ?? []`. On **any** transient fetch failure on the first ingest, `items = []`, nothing is registered, and `dedupIndexInitialized = true` (line 352) — **permanently, for the whole process**. Every later ingest calls `findDuplicate` against an **empty** candidate set → no duplicate is ever found → **every copy, including a byte-identical re-copy, creates a new `HistoryItem`**. Unlike `commit()` (which logs at `:200`), this swallow emits **no log**. |
| **Impact** | Silent history-shape corruption (duplicate accumulation) for the whole session, zero diagnostic. |
| **Recommendation** | On init-fetch failure: **log + either retry-on-next-ingest (don't flip `dedupIndexInitialized`) or fail-loud** so it is diagnosable. The current fail-silent is the worst option. |
| **Why it outranks DS-002** | DS-002 is transient + self-healing + non-destructive. This is persistent-for-session + silent + accumulates. Comparable trigger likelihood. |

### `NEW-history-spine-1` — Defaults-driven reload does a full `load()` instead of `reconcileWithStore()`

| | |
|--|--|
| **Location** | `History.swift:760-766` (`loadAfterDefaultsChange`) → `load()` 269-285 (esp. `:272`); contrast `reconcileWithStore` 446-484 |
| **Mechanism** | Flipping sort order or pin direction in Settings calls `load()`, which unconditionally does `all = autoreleasepool { sorter.sort(results).map { HistoryItemDecorator($0) } }` — **fresh decorators for every row**, discarding decoded/cached images and invalidating held decorator-id references (selection, `VisibilityTracker`). `reconcileWithStore()` already does the right thing (reuses decorators by `persistentModelID`, 455-466). |
| **Impact** | A trivial Settings toggle triggers a full decorate + image re-decode storm. |
| **Recommendation** | Route `loadAfterDefaultsChange` through `reconcileWithStore()` (re-sort in place). |
| **Sharpens** | DS-004 (load cost) — the audit saw the unbounded fetch but missed this needlessly-destructive reload path. |

### `NEW-history-spine-2` — `syncAllToStore` is O(rows)+O(n) on **every copy**

| | |
|--|--|
| **Location** | `History.swift:420-441` (def); sole caller `insertIncrementally:407` (the per-copy `.added`/`.merged` path) |
| **Mechanism** | `Set((try? ...fetchIdentifiers(FetchDescriptor<HistoryItem>())) ?? [])` fetches **all** row identifiers, then a linear scan over `all` (425-434). The comment at `:418` self-acknowledges "the only O(n) piece of the incremental path" — but the catalog never enumerates it, and the roadmap's "incremental per-copy reconcile" framing obscures that the hot path is **O(rows) in DB size**, not O(log n). At n=1000: 1000 IDs fetched + 1000 decorators scanned on **main**, per copy. |
| **Recommendation** | Have the ingest actor return the `deletedItemIDs` it already computes (the trim+dup-delete set) and apply those directly, instead of re-fetching the whole table. |
| **Connects to** | BS-4/6 read-path/perf work. Pairs with `NEW-ingest-dualpath-1`. |

### `NEW-ingest-dualpath-1` — per-ingest full unpinned fetch+sort in `commit`

| | |
|--|--|
| **Location** | `ClipboardIngestor.swift:415-419` (inside `commit(_:deleting:limit:)`, called from `ingest`@155 every copy) |
| **Mechanism** | To enforce the size limit it issues `FetchDescriptor<HistoryItem>(predicate: $0.pin == nil, sortBy: lastCopiedAt reverse)` and fetches **all unpinned rows** every ingest, solely to compute `unpinned.dropFirst(limit-1)`. O(n) fetch + O(n log n) sort per copy on the actor; `SignatureIndex` doesn't help (it tracks dedup candidates, not insertion/count order). Compounds DS-020 (a copy storm queues N of these). |
| **Recommendation** | Maintain a count / ordered tail in the actor (the index already enumerates items), or have the store enforce the cap. |
| **Connects to** | `NEW-history-spine-2` — together they're the two O(n) walls on the per-copy path. |

### `NEW-storage-load-models-1` — `newBackgroundContext()` is prod-dead **and** its docstring falsely claims production use

| | |
|--|--|
| **Location** | `Storage+Background.swift:17-21` (`newBackgroundContext`), `:39-42` (`fetchWindow` docstring); `ClipboardIngestor.swift:126` (actor builds context inline) |
| **Mechanism** | `newBackgroundContext()` has exactly one caller: `StorageBackgroundContextTests.swift:11`. The prod actor builds its context inline via `DefaultSerialModelExecutor(modelContext: ModelContext(modelContainer))`. The `fetchWindow` docstring (`:41`) states *"Production calls this from a background Task holding a `Storage.newBackgroundContext()`..."* — **doubly false**: `fetchWindow` has zero prod callers **and** `newBackgroundContext` has zero prod callers. |
| **Impact** | Both APIs in `Storage+Background.swift` are test-only, and the docstring actively misrepresents the production architecture. |
| **Recommendation** | Decide wire-vs-delete for the whole file (Load ADR D0); **either way, delete the false "production calls this" claim**. |
| **Sharpens** | DS-004 — the audit flagged the loader half only. |

### `NEW-singletons-intents-misc-1` — ~250 LOC dead paste-stack / multi-select subtree

| | |
|--|--|
| **Location** | `PasteStack.swift` (72), `History+PasteStack.swift` (102), `PasteStackView.swift`/`PasteStackPreviewView.swift`/`PasteStackItemView.swift`; entry points `AppState.swift:71-74,117-119`, `HistoryItemView.swift:60-61`, `KeyChord.swift:46-49,102-125`, `KeyHandlingView.swift:104-135` |
| **Mechanism** | `multiSelectionEnabled` is an immutable `let = false` (`AppState.swift:15`, no other assignments). Its one enabled entry — ⌘-click → `addToSelection` (`HistoryItemView.swift:61`) — is the **only** caller of `NavigationManager.addToSelection`, so `addToSelection` is unreachable; it alone sets `isManualMultiSelect`, so `isMultiSelectInProgress` is **always false**; `startPasteStack` is **additionally** guarded by `guard multiSelectionEnabled` (`History+PasteStack.swift:16`) — a double lock. Net: `pasteStack` is forever nil; ~174 LOC of model+extension, 3 views, and every `pasteStack`/`pasteStackSelected` branch across ContentView/Toolbar/Slideout/HistoryList/KeyHandling/SlideoutController/NavigationManager/Clipboard are dead, plus 4 `KeyChord` `extendTo*` cases and 4 `KeyHandlingView` guards. |
| **Recommendation** | **Decision needed:** is multi-select/paste-stack a staged feature or abandoned? If abandoned, delete the subtree (high-value, low-risk cleanup). |
| **Sharpens** | DS-028 — the audit saw the switch; not the ~250 LOC it gates. |

### `NEW-singletons-intents-misc-3` — App Intents index into search-filtered `items`; "item N" is ambiguous under a query

> **Resolved 2026-07-11 (`cd368ea`):** `AppHistoryCommandService` is now the single positional boundary and resolves against `History.all`. Characterization coverage holds `items` filtered while proving position 1 still addresses the first full-history item.

| | |
|--|--|
| **Location** | `Intents/Select.swift:26-33`, `Delete.swift:22-28`, `Get.swift:49-50`; filter reassignment `History.swift:920` |
| **Mechanism** | `History.items` is a stored var that `applySearchResults` reassigns to the matched subset (`items = rebuilt`, `:920`). Closed-popup → empty query → `items == all` (documented behavior). But an open popup with an active query makes `items[number-1]` resolve to the Nth **visible search match** instead. The intent descriptions say "1-based position in history," so positional semantics silently depend on transient popup search state. |
| **Recommendation** | Intents should resolve against `all` (or a documented "filtered view" contract), not the shared `items`. |
| **Impact** | Medium-Low (requires the intent to fire while the popup holds a query). Genuine latent semantics bug, unflagged. |

---

## Low

### `NEW-history-spine-3` — `load()` doesn't bump `searchGeneration`

| | |
|--|--|
| **Location** | `History.swift:269-285` vs guard `:896`; via `loadAfterDefaultsChange:760-766` |
| **Mechanism** | `load()` replaces `all` with fresh decorators (new UUIDs, `:272`) without bumping generation. A Defaults-change reload during an in-flight non-empty search → the stale-gen `applySearchResults` does `all.first { id == dto.id }` for old ids → all nil → `items = []` → brief empty result list. Same class as DS-013. |
| **Recommendation** | `invalidateInFlightSearch()` at the top of `load()` (or bump generation before replacing `all`). |

### `NEW-history-spine-4` — `select()` clears the query in a deferred `Task`, never invalidates

| | |
|--|--|
| **Location** | `History.swift:665-699` (`select`); query clear in `Task` at `696-698` |
| **Mechanism** | `select` neither invalidates nor clears the query synchronously — it wraps `searchQuery = ""` in a `Task {}`, leaving any in-flight search uncancelled. Impact low (popup closes at `:673/681/684/688` before a stale apply is visible), but it's the same un-cancelled-in-flight pattern as DS-013. |

### `NEW-ingest-dualpath-2` — dedup read path mutates non-matching candidate rows

> **Resolved 2026-07-11 (`f9f0e85`):** duplicate search now returns candidate models without mutating them; surviving-candidate backfill runs inside the ingest transaction.

| | |
|--|--|
| **Location** | `ClipboardIngestor.swift:308` (call in `findDuplicate`), `:332-341` (`backfillMissingFingerprints`) |
| **Mechanism** | For each candidate, `findDuplicate` calls `backfillMissingFingerprints(in: candidate)`, which **sets `content.fingerprint`** on candidate `@Model` rows as a side effect. A non-matching candidate (supersedes false) is left with persisted fingerprints it didn't have. Piggybacks on the caller's txn (no extra save) and is idempotent, but a read lookup writes unrelated rows. |

### `NEW-ingest-dualpath-3` — `MainActorIngestorAdapter.ingest(_:)` is fully dead

| | |
|--|--|
| **Location** | `ClipboardIngestor.swift:15-21` (method) + `:14` (conformance) |
| **Mechanism** | `ingest(_:)` (calls `History.shared.add`, returns nil event) is **never invoked** — `MainActorIngestorAdapter(` → 0 instantiation sites; `ClipboardIngestorTests:25` uses only the static `historyItem(from:)`. So the method + the `ClipboardIngestor` conformance are unreachable dead code today. |
| **Sharpens** | DS-016 — not "residual," **fully dead**. |

### `NEW-ingest-dualpath-4` — fire-and-forget ingest discards `IngestResult`

| | |
|--|--|
| **Location** | `Clipboard.swift:237` (`Task { await ingestor.ingest(request) }`) |
| **Mechanism** | The dispatch discards the return value. On persistence failure the actor returns `IngestResult(event: nil, …)` after `logger.error` — `History.consume` is never called, no item appears, the only signal is a log line. No `lastPersistError`, no retry, no user-visible indication that a copy was lost. **Ingest-side analog of DS-023.** |

### `NEW-dedup-ids-2` — `findDuplicate` re-derives `ContentSignatureEntry` inline (unmaintained parity invariant)

> **Resolved 2026-07-11 (`10f8d90`):** `signatureDTO(of:)` is the single projection used by both `snapshot(of:)` and candidate lookup.

| | |
|--|--|
| **Location** | `ClipboardIngestor.swift:292-298` vs `Dtos.swift:141-148` |
| **Mechanism** | The index keys were registered by `snapshot(of:)` (Dtos 141-148); `findDuplicate` re-derives entries inline with the same shape. Candidate lookup only hits on **exact** equality, so correctness depends on two independent derivations staying byte-identical — an unmaintained invariant. If `snapshot()`'s size/fingerprint rule ever drifts, dedup silently degrades to always-create-new with no test necessarily catching it. |
| **Recommendation** | `findDuplicate` should reuse `snapshot(of: item).signature.entries`. |

### `NEW-dedup-ids-3` — `backfillMissingFingerprints` is a write side-effect in a read query, committed by a later unrelated ingest

> **Corrected/resolved 2026-07-11 (`f9f0e85`):** Apple documents that `ModelContext.transaction` writes pending changes when its closure finishes, so the claimed later-save timing was false. The real read/write coupling was still removed, and a forced closure failure plus fresh-context fetch proves atomic rollback.

| | |
|--|--|
| **Location** | `ClipboardIngestor.swift:308` (call), `:332-341` (body), `:199-205` (commit-throw path) |
| **Mechanism** | `findDuplicate` (a read) sets `content.fingerprint` on candidates; that mutation is **not saved inside `findDuplicate`** — it "piggybacks on commit's save." But `commit` runs **after** `findDuplicate` (208 vs 188), and if `commit` throws (caught 199-205, no save), the backfilled mutations stay pending on the long-lived actor context and get committed by the **next** successful ingest's unrelated save. Idempotent/correct, but the read/write coupling + cross-ingest commit timing is a design smell. |

### `NEW-clipboard-filter-1` — `filteredTypes(_:)` is a 4th dead Clipboard helper

| | |
|--|--|
| **Location** | `Clipboard.swift:278-292` (internal, not private) |
| **Mechanism** | Zero call sites in prod+tests. Commit `9cb7d3f` "chore(deadcode)" removed `contents(from:)` — its sole caller — but left `filteredTypes` orphaned. |
| **Sharpens** | DS-008 — the audit listed 3 dead helpers; this is a 4th, and it's `internal` (pollutes module API). |

### `NEW-clipboard-filter-2` — `supportedTypes`/`disabledTypes` cascade is dead

| | |
|--|--|
| **Location** | `Clipboard.swift:44-53` (`supportedTypes`), `:61` (`disabledTypes`) |
| **Mechanism** | `supportedTypes` → read only by `disabledTypes` → read only by the dead `filteredTypes`. So both have zero live readers. **Refines DS-008:** the 8-type "dual config drift" for `supportedTypes` is **dead-vs-live** (Clipboard side dead, actor side live), not the live-vs-live drift the audit's wording implies; only the 3 `ignoredTypes` markers are genuine live-vs-live duplication. |

### `NEW-clipboard-filter-3` — 5 doc comments reference `Clipboard.contents(from:)`, which no longer exists

| | |
|--|--|
| **Location** | `IngestFilter.swift:7,:64`; `ClipboardIngestor.swift:134,:440`; `IngestFilterTests.swift:6` |
| **Mechanism** | `func contents(from item: NSPasteboard.Item)` was removed in `9cb7d3f`, but five doc comments still cite it as a live Clipboard method whose filtering `IngestFilter` mirrors — most prominently `IngestFilter.swift:64` framing the whole module as the "twin of … `Clipboard.contents(from:)`". Engineers will search for a nonexistent anchor. |
| **Recommendation** | Rewrite those comments; the real anchor is `checkForChangesInPasteboard`. |

### `NEW-storage-load-models-2` — `HistoryItem.init(contents:)` self-assigns timestamps (no-op, misleading)

| | |
|--|--|
| **Location** | `HistoryItem.swift:112-116` |
| **Mechanism** | The init body runs `self.firstCopiedAt = firstCopiedAt` / `self.lastCopiedAt = lastCopiedAt`, but the signature has only a `contents` parameter — each RHS resolves to the instance property itself (default `Date.now` @88-89). Both lines are no-op self-assignments. Harmless (callers overwrite timestamps), but misleading dead code suggesting injection that doesn't happen. |

### `NEW-singletons-intents-misc-2` — duplicated 1-based index + bounds + notFound across 3 Intents

> **Resolved 2026-07-11 (`cd368ea`):** Get, Select, and Delete delegate to one private one-based resolver in `AppHistoryCommandService`; zero, negative, and out-of-range positions share the same `notFound` behavior.

| | |
|--|--|
| **Location** | `Intents/Get.swift:24,48-51`, `Select.swift:22,27-29`, `Delete.swift:19,23-25` |
| **Mechanism** | Each independently declares `private let positionOffset = 1` and repeats `let index = number - positionOffset; guard index >= 0, items.count > index else { throw .notFound }`. A shared `resolvedIndex(for:in:)` (or extension) collapses three copies of the off-by-one convention. (Pairs with DS-018's Intent-port work.) |

---

## Cross-cutting observation: the `searchGeneration` bug class

Three of the Low findings (`NEW-history-spine-3`, `NEW-history-spine-4`) plus DS-013 are the **same defect** — a list/order mutation that forgets to invalidate the in-flight search. The audit sampled it once (togglePin). The verification found two more live sites (`load`, `select`) and the structural cause: **generation discipline is not centralized** — each mutation must remember to call `invalidateInFlightSearch()`. This is the strongest argument for handling it during the History split (Wave B) via a single mutation chokepoint, rather than as isolated one-line patches.
