# 04 — Correctness Wave A Plan (grilled, decided)

**Baseline:** HEAD `6cd37c8` · **Status:** plan only — no product code changed. · **Output of the `/grill-with-docs` session.**

This is the concrete, ordered execution plan for the **correctness/safety wave** — the theme the user chose for this cycle. It operationalizes the recalibrated priority order from [`00-executive-verdict.md §4`](00-executive-verdict.md). All four approach decisions are resolved (see "Decisions" below). Waves B–F follow `00 §4` and the design-audit playbook (`19`), to be drilled when reached.

## Decisions (locked by grilling)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Cycle theme | **Correctness/safety first** (fixes the silent-failure cluster + generation bug-class; low-risk, no UX change) |
| 2 | `NEW-dedup-ids-1` fix | **Log + backoff retry** (don't permanently disable dedup; self-heals within session; bounded cost under persistent failure) |
| 3 | Error-swallowing cluster scope | **Unified `lastPersistError` + log, no new UI** (DS-002 mirrors sibling `reconcileWithStore`; user-visible error surface deferred to a separate product decision) |
| 4 | Generation bug-class scope | **Patch all 3 sites + per-site TDD** now; centralize invalidation in a chokepoint during Wave B (History split) |

## Hard rules for every step (from CLAUDE.md / playbook)

- One finding per commit. TDD: **failing test first**, then minimal fix, then run focused test.
- Commit message names the item: `fix(new-dedup-ids-1): …`, `fix(ds002): …`, etc. Source comments stay clean Apple docstrings (no `DS-`/audit tags in `Maccy/`).
- No local toolchain — push, then drive `macOS 26 ARM CI` via `gh`; poll **no more often than every 30 s** (run ≈ 11 min). Green CI is the only acceptance.
- Do not change user-visible behavior (these are bug fixes; the error-swallowing step deliberately adds no UI).
- While dual write paths exist, a test on `add` ≠ proof for `consume` — keep dedup/ingest tests on the actor path.

---

## Step sequence (ordered)

> Order rationale: `NEW-dedup-ids-1` first (rank #1, most serious, independent actor code); then `DS-002` (the playbook's "A0 before any syncAll/consume change"); then the error-swallowing cluster (load + ingest call sites); then the generation bug-class (load/select/togglePin). Each step is independently CI-gated.

### Step 1 — `NEW-dedup-ids-1`: retry + log dedup-index init (no silent disable)

| | |
|--|--|
| **Closes** | `NEW-dedup-ids-1` (silent session-wide dedup disable) |
| **File** | `Maccy/Ingest/ClipboardIngestor.swift:346-353` (`ensureDedupIndexInitialized`) |
| **Fix** | On `fetch` throw: `logger.error("Dedup index init failed; will retry on next ingest", …)`. Do **not** set `dedupIndexInitialized = true`. Add a consecutive-failure counter with exponential backoff by ingest count (e.g. retry every `2^min(failures,5)` ingests) so a deterministically-broken store does not turn every copy into a full-table fetch; once a retry succeeds, reset. |
| **Failing test (TDD)** | `ClipboardIngestorDedupTests`: fault-inject the init `fetch` to throw on the first 2 calls then succeed; assert (a) a re-copy after recovery **merges** (not creates a new item), (b) a log is emitted on failure, (c) while failing, ingestion does not attempt a full fetch on *every* copy (backoff bound). |
| **Commit** | `fix(new-dedup-ids-1): retry+log dedup index init instead of silent disable` |
| **Risk** | Low — the flag simply stays `false` until success. |
| **CI gate** | `MaccyTests/ClipboardIngestorDedupTests` green; existing dedup tests unchanged. |

### Step 2 — `DS-002`: abort `syncAllToStore` on fetch failure

| | |
|--|--|
| **Closes** | `DS-002` (fetch-fail → wipe all decorators) |
| **File** | `Maccy/Observables/History.swift:420-441` (`syncAllToStore`) |
| **Fix** | Mirror the sibling `reconcileWithStore` (446-453): wrap the `fetchIdentifiers` in `do/catch`; on catch, `recordPersistenceError("syncAllToStore identifier fetch failed", error)` and `return` **without mutating `all`**. |
| **Failing test (TDD)** | `HistorySyncAllTests`: fault-inject `fetchIdentifiers` to throw; assert `all` is unchanged, `lastPersistError` is set, and `items` is not cleared. |
| **Commit** | `fix(ds002): abort syncAllToStore on fetch failure instead of wiping` |
| **Risk** | Low — the correct pattern already exists 26 lines below. |
| **CI gate** | `MaccyTests/HistorySyncAllTests` + existing `HistoryConsumeTests` green. |
| **Dep note** | This is the playbook's "A0" — land it before any other `syncAll`/`consume`/incremental change. |

### Step 3 — Error-swallowing cluster (load + ingest) — 2 commits

#### 3a — `DS-023`: surface load/prewarm persistence errors

| | |
|--|--|
| **Closes** | `DS-023` (ContentView `try? await load`; `AppState.prewarmVisibleWindow` `try?`) |
| **Files** | `Maccy/ContentView.swift` (`try? await history.load()`); `Maccy/Observables/AppState.swift` (`prewarmVisibleWindow`, `:97-103`) |
| **Fix** | Replace `try?` with `do/catch`; on catch, `history.recordPersistenceError(...)` (or set `lastPersistError`) + `logger.error`. Do **not** silently present an empty UI as if legitimate. (No new UI widget — Decision 3.) |
| **Failing test** | `ContentViewLoadErrorTests` / `AppStatePrewarmTests`: fault-inject `load` to throw; assert `lastPersistError` set and a log emitted. |
| **Commit** | `fix(ds023): surface load+prewarm persistence errors via lastPersistError` |

#### 3b — `NEW-ingest-dualpath-4`: observe ingest failures on the main side

| | |
|--|--|
| **Closes** | `NEW-ingest-dualpath-4` (fire-and-forget ingest discards `IngestResult`) |
| **File** | `Maccy/Clipboard.swift:237` (`Task { await ingestor.ingest(request) }`) |
| **Fix** | Observe the returned `IngestResult`; when `event == nil` after a logged actor failure, surface to `lastPersistError` on main (`MainActor.run`) so a lost copy is diagnosable rather than silent. (The actor already logs at `ClipboardIngestor.swift:200`.) |
| **Failing test** | `ClipboardIngestErrorPropagationTests` (exists): drive a commit failure; assert `lastPersistError` set on main. |
| **Commit** | `fix(new-ingest-4): surface ingest persistence failures via lastPersistError` |
| **Risk** | Low-medium (touches the dispatch site; keep the fire-and-forget structure, only observe the result). |

### Step 4 — Generation bug-class — 3 commits (one per site)

All three add a single `invalidateInFlightSearch()` call (the same call `clear`/`clearAll`/`delete` already make). Each gets its own failing test that triggers the mutation during an in-flight search and asserts the final `items`/highlights are stable.

| Sub | Site | File:line | Test assertion | Commit |
|-----|------|-----------|----------------|--------|
| 4a | `togglePin` | `History.swift:702` | pin during in-flight search → no stale-order apply | `fix(ds013): invalidate in-flight search on togglePin` |
| 4b | `load` | `History.swift:269` (before replacing `all`) | Defaults-change reload during search → no empty result list | `fix(new-history-3): invalidate in-flight search on load` |
| 4c | `select` | `History.swift:665` (with query clear) | select during in-flight search → no stale apply | `fix(new-history-4): invalidate in-flight search on select` |

**Wave B TODO (recorded, not done now):** during the History split, centralize "any list/order mutation cancels in-flight search" into a single chokepoint so the discipline is structural, not per-call-site. This is the structural root-cause fix for the bug-class; doing it now would duplicate Wave B work.

---

## Acceptance for the wave

- [ ] `NEW-dedup-ids-1`: transient init-fetch failure no longer disables dedup for the session; recovery + log verified.
- [ ] `DS-002`: `fetchIdentifiers` throw leaves `all` intact and sets `lastPersistError`.
- [ ] `DS-023` + `NEW-ingest-dualpath-4`: load + ingest failures surface via `lastPersistError` (no silent empty/lost copy).
- [ ] `DS-013` + `NEW-history-spine-3/4`: pin/load/select during in-flight search no longer produce stale/empty results.
- [ ] All steps CI-green on `macOS 26 ARM CI`; no user-visible behavior change; Wave B chokepoint TODO recorded.

## What is explicitly NOT in this wave

- User-visible error UI (Decision 3 — separate product decision).
- The `searchGeneration` chokepoint centralization (Wave B).
- The per-copy O(n)×2 perf fixes (`NEW-history-spine-2`, `NEW-ingest-dualpath-1`) — perf theme, later.
- History split / dual-path convergence (Wave B), dead-subtree cleanup (DS-028 / `NEW-singletons-intents-misc-1`), Load ADR (Wave D).
