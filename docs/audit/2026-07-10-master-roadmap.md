# 2026-07-10 Master Roadmap — the complete path after Wave A

| Field | Value |
|-------|-------|
| **Role** | The single forward-looking roadmap: what to do after Wave A, in order, with dependencies and decision forks. Supersedes the design-audit playbook (`2026-07-09-design-structure-audit/19-master-playbook.md`) priority order using the verification's recalibration + Wave A completion. |
| **Baseline** | post-Wave-A master (HEAD after `7fb08bd`). |
| **Inputs** | [`2026-07-09-design-audit-verification/`](2026-07-09-design-audit-verification/) (verified findings + 19 new issues), [`2026-07-09-design-structure-audit/19-master-playbook.md`](2026-07-09-design-structure-audit/19-master-playbook.md) (waves), [`../2026-06-27-memory-floor-and-retention/`](2026-06-27-memory-floor-and-retention/) (memory track). |
| **Constraint** | No local toolchain; one small step + TDD + CI per change; structure ≠ behavior in the same PR; don't change user-visible behavior unless required. |

---

## 1. Where we are (Wave A complete)

**Landed & CI-green** (commits `2edb2cc` → `7fb08bd`):

| Step | Finding | Fix |
|------|---------|-----|
| 1 | `NEW-dedup-ids-1` | dedup init retries+logs instead of silently disabling for the session |
| 2 | `DS-002` | `syncAllToStore` records + returns on fetch failure instead of wiping `all` |
| 3a | `DS-023` | load failures recorded via `loadAndRecordError` (not `try?`-swallowed) |
| 3b | `NEW-ingest-dualpath-4` | ingest persistence failures surface on `lastPersistError` (not discarded) |
| 4 | `DS-013` + `NEW-history-spine-3/4` | `togglePin`/`load`/`select` invalidate in-flight search |
| (+) | `file_length` / shards | `HistoryPersistence` extracted; test shards consolidated 9→5 |

**What this closed:** the entire **silent-failure cluster** (4 distinct swallow sites — now all surface to `lastPersistError`) and the **search-generation bug class** (3 sites now bump generation like their siblings). The most dangerous correctness defects in the verification are gone.

**What remains:** structure debt (the god object), measured perf walls on the hot path, domain-consistency cleanup, and ~250 LOC of dead feature subtree.

---

## 2. Strategy — three themes + cleanup

The verification showed the audit's *mechanisms* were right but its *severity* was inflated. The remaining work is therefore **not** a fire drill — it's debt paydown ordered by leverage:

1. **Structure spine (Wave B)** — `History` (989 LOC god object) + the `History→AppState` ×23 coupling + the dual write path. This is the single largest blocker to *safe* change; almost every other item touches `History`. **Highest leverage.**
2. **Hot-path performance (Wave D)** — two O(n)-on-every-copy walls (`syncAllToStore`, `commit`'s unpinned fetch) + the unbounded cold `load` + the MainActor hop. This is the real story behind the "incremental per-copy" label and ties directly to the BS-4/6 memory track.
3. **Domain consistency (Wave C)** — dual filter rules, dual search engines, the `SignatureIndex` delete-sync gap, three-identifier confusion. Mostly Medium/Low after recalibration; batchable.
4. **Cleanup & boundaries (Wave E–F)** — ~250 LOC dead paste-stack subtree, dead Clipboard helpers, Intent port, doc rot, progressive DI.

**Sequencing principle:** structure (B) before the History-touching items in C/D (so they're safe to make); decisions (D0 Load ADR) early because they gate downstream work; low-risk cleanup interleaves anywhere.

---

## 3. The ordered roadmap

> Effort: S/M/L. Risk: L/M/H. Each step = one PR (TDD + CI). Hard deps in §3.5.

### Wave B — Structure spine (the god object)

| # | Step | Closes | Effort | Risk | Notes |
|---|------|--------|--------|------|-------|
| B0 | **History split design** (doc-only) | DS-001 | S | — | Decide facade name (`History`) + the 5–7 partition types (ListState / StoreProjector / SearchSession / Mutations / LegacyWriter + UIEffectPort). Output = an ADR. |
| B1 | **UIEffectPort (DEFERRED — tried & reverted 2026-07-10)** | DS-007 | — | — | A protocol+adapter that wraps `AppState.shared` only *relocates* the coupling — the adapter still calls `AppState.shared` in every method, so runtime is unchanged and testability isn't unblocked ("脱裤子放屁"). The real fix is **inversion** (History publishes effect intents; UI subscribes), which belongs with the projection split (B2), not a standalone port. Defer. |
| B2 | **History file split** (no behavior) | DS-001, DS-022 | M–L | M | One file per commit (`refactor(history): split … no behavior change`). Also routes all store IO through one port (closes the dual persistence channel). Order: Legacy → Search → Reconcile → Mutations. |
| B3 | **Migrate tests off `add`** | DS-003 | M–L | M | `seedViaConsume` helper; quarantine sessionLog-only tests. 45 `history.add` call sites across 5 test files. |
| B4 | **Remove/isolate legacy `add`** | DS-003, DS-016 | M | M | After B3. Delete `MainActorIngestorAdapter.ingest` (fully dead). |
| B5 | **Centralize generation chokepoint** | (Wave A TODO) | S | L | Fold the `invalidateInFlightSearch()` calls (now in 6 sites) into one "any list mutation cancels in-flight search" entry point. Structural fix for the bug class Wave A patched per-site. |

### Wave C — Domain consistency (after B2 for History-touching items)

| # | Step | Closes | Effort | Risk |
|---|------|--------|--------|------|
| C1 | Single filter source | DS-008, `NEW-clipboard-filter-1/2/3` | M | M | Shared UTI constants; delete 4 dead Clipboard helpers + the dead `supportedTypes`/`disabledTypes` cascade; fix `contents(from:)` doc rot. |
| C2 | `SignatureIndex` sync on UI delete | DS-009 | M | M | **No rebuild trigger exists today** (verification-sharpened). Prefer dirty-rebuild, or `ingestor.noteRemoved`. Correctness currently held by `supersedes` containment — Low severity, but the stale-candidate growth is unbounded. |
| C3 | Single `MatchEngine` + empty short-circuit | DS-010, DS-012, DS-029 | M | M | Merge legacy `Search` (217 LOC) into `SearchActor`; O(1) decorator-id resolve (`[UUID: HistoryItemDecorator]`); pin the one-item corpus-lag. |
| C4 | Batch limit deletes | DS-014 | S | M | One transaction for `limitHistorySize` trim (matches the actor's batched trim). |
| C5 | Pin query off the entity | DS-015 | S | L | `HistoryItem.availablePins` reads `Storage.shared` — move to a PinService. |
| C6 | ItemID stability study | DS-019 | M | H | **Recalibrated to Low** (ItemID not persisted → no cross-relaunch break). Document the latent reliance on `String(describing:)`; a stored UUID column only if a concrete need appears. Probably **defer**. |

### Wave D — Read & hot paths (perf; ties to BS-4/6 memory)

| # | Step | Closes | Effort | Risk |
|---|------|--------|--------|------|
| D0 | **Load ADR** (decision) | DS-004, `NEW-storage-load-models-1` | S | — | **Wire vs delete `VisibleWindowLoader`**; either way kill the false "production calls this" docstring on `newBackgroundContext` (which is itself prod-dead). Needs your call (§5). |
| D1 | Implement the load decision | DS-004 | L | H | Windowed load (or confirmed deletion). The big memory win — unbounded `load` faults the whole table into `mainContext`. Needs memory-suite literacy. |
| D2 | Shrink the MainActor hop | DS-011 | M | M | Snapshot `Defaults` off the hot path; evaluate off-main rich text with fixtures. |
| D3 | Ingest coalesce | DS-020 | M | M | Product decision: latest-wins mailbox vs current one-Task-per-changeCount. |
| D4 | `syncAllToStore` O(n)→O(deleted) | `NEW-history-spine-2` | M | M | Have the ingest actor return the `deletedItemIDs` it already computes; apply those directly instead of re-fetching all identifiers on every copy. |
| D5 | `commit` per-copy full fetch→maintained count | `NEW-ingest-dualpath-1` | M | M | Track an ordered/counted tail in the actor so the size-trim doesn't fetch+sort the entire unpinned table every copy. |
| D6 | Defaults-reload uses reconcile, not full load | `NEW-history-spine-1` | S | L | `loadAfterDefaultsChange` → `reconcileWithStore` (reuse decorators, avoid image re-decode storm). |

### Wave E–F — Boundaries & hygiene (low-risk, interleaves anywhere)

| # | Step | Closes | Effort | Risk |
|---|------|--------|--------|------|
| E1 | Intent port | DS-018, `NEW-singletons-intents-misc-2/3` | M | L | `HistoryCommandService` protocol; de-duplicate the 1-based index logic; resolve intents against `all` (not search-filtered `items`). |
| E2 | Package moves (no behavior) | DS-026, DS-034 | M | L | `CompositionRoot` + `DebugHooks` split; colocate `Search*` under `Search/`. |
| E3 | Timer / multiSelect | DS-024, DS-028 | S | L | Timer `tolerance` + `.common`; decide the dead `multiSelectionEnabled` subtree. |
| E4 | **Delete dead paste-stack subtree** | `NEW-singletons-intents-misc-1` | S | L | ~250 LOC unreachable (PasteStack model + extension + 3 views + KeyChord/KeyHandling branches), gated by always-false `multiSelectionEnabled`. **Needs your decision** (§5). |
| E5 | Progressive DI vs `shared` | DS-006 | ongoing | M | Stop new `*.shared` call sites; inject at boundaries. 175 occurrences / 26 files — whittle, don't big-bang. |

### 3.5 Hard dependencies

```text
B0 → B1 → B2 → (B3 → B4)              # structure spine; B5 after B2
D0 → D1                                # load ADR gates the load rewrite
B2 before C2/C3/C4 (they edit the split History)
C6 deferred (Low); D4/D5 pair with BS-4/6 memory work
E4 (dead subtree) needs your delete/keep decision
```

---

## 4. The 19 verification-found issues → wave mapping

| New ID | Sev | Wave | Status |
|--------|-----|------|--------|
| `NEW-dedup-ids-1` | Med (top) | **A** | ✅ done |
| `NEW-history-spine-1` Defaults-reload full load | Med | D6 | open |
| `NEW-history-spine-2` syncAll O(n)/copy | Med | D4 | open |
| `NEW-history-spine-3` load no gen bump | Low | **A** | ✅ done |
| `NEW-history-spine-4` select no invalidate | Low | **A** | ✅ done |
| `NEW-ingest-dualpath-1` commit O(n)/copy | Med | D5 | open |
| `NEW-ingest-dualpath-2` read mutates candidates | Low | C2 | open |
| `NEW-ingest-dualpath-3` adapter fully dead | Low | B4 | open (B4 removes it) |
| `NEW-ingest-dualpath-4` result discarded | Low | **A** | ✅ done |
| `NEW-dedup-ids-2` findDuplicate re-derives signature | Low | C2 | open |
| `NEW-dedup-ids-3` backfill cross-ingest commit | Low | C2 | open |
| `NEW-clipboard-filter-1/2/3` dead helpers + doc rot | Low | C1 | open |
| `NEW-storage-load-models-1` dead newBackgroundContext + false doc | Med | D0 | open |
| `NEW-storage-load-models-2` init self-assigns timestamps | Low | C (hygiene) | open |
| `NEW-singletons-intents-misc-1` dead paste-stack subtree | Med (cleanup value) | E4 | open (decision) |
| `NEW-singletons-intents-misc-2/3` intent dup + filtered-index ambiguity | Low/Med-Low | E1 | open |

---

## 5. Decision forks (need your call — these gate work)

1. **D0 — Load:** wire `VisibleWindowLoader`, delete it, or keep test-only + fix the docstring? (The biggest memory lever; also kills the false "production calls this" claim.)
2. **E4 — Dead paste-stack / multi-select subtree (~250 LOC):** delete it, or is multi-select a staged feature being kept warm?
3. **B0 — History split granularity:** the full 5–7 types, or a smaller first cut (e.g., just peel `LegacyWriter` + `UIEffectPort`)?
4. **C6 — ItemID:** keep the derived `String(describing:)` form (Low risk, document it), or invest in a stored UUID column now?
5. **C2 — SignatureIndex delete-sync:** `noteRemoved` on the actor, dirty-rebuild on next ingest, or wait for unified events (Wave B's event model)?
6. **D3 — Ingest coalesce:** latest-wins mailbox, or keep one-Task-per-change (accept storm cost)?

---

## 6. Near-term plan (the next 3–5 concrete moves)

1. **Push `7fb08bd`** (Wave A Step 3b) once Step 4 greens → Wave A fully landed.
2. ~~Commit the verification doc suite~~ — **done** (`876de39`).
3. **Resolve D0 (Load ADR) + E4 (dead subtree)** — two quick decisions that unblock D1 and a big cleanup.
4. **D4 — `syncAllToStore` O(n)→O(deleted)** — concrete, measured perf win on every copy (have the ingest actor return the `deletedItemIDs` it already computes instead of re-fetching all identifiers). The right kind of next step: concrete value, not ceremony. (B1 UIEffectPort was reverted — hollow; see §3 Wave B.)

Parallel-safe: C1 (filter cleanup — different files) and E1 (Intent port) can run alongside B without conflict.

---

## 7. Red lines & over-design traps (do not)

- **Don't** weaken post-hash `==` in `dataLikelyEqual`; **don't** casual-edit the C++ UTF-8 validation; **don't** split the ingest single transaction; **don't** drop the search generation/title-equality guards; **don't** `mainContext.reset()` for memory.
- **Don't** move directories + change dedup + change load in one PR (un-bisectable).
- **Don't** build a generic `EventBus`, a search index without measured need, a repository pyramid for one SQLite aggregate, or a full DDD package tree in one migration.
- **Don't** reword log/error messages to dodge the CI self-scan — allowlist expected fault-injection logs instead (locked principle, 2026-07-09).
- **Don't** add to `History.swift` without checking `file_length` headroom (it's at ~978 after extraction; the split (B2) is the real cure).

---

## 8. Cross-cutting tracks (run in parallel, don't fight the structure work)

- **Memory / BS-4/6/8** (`2026-06-27-memory-floor-and-retention/`): the load rewrite (D1) and the per-copy O(n) fixes (D4/D5) are the Swift-side memory levers; the image-cache/blob-pool work is separate. Structure (B) *enables* clean memory fixes (e.g., a `StoreProjector` that can release decorators).
- **Docs / real-time tracking**: keep `INDEX.md` → this roadmap as the live plan; the design audit (`02`/`17`) remains the mechanism authority; the verification (`01` verdicts) the severity authority.

---

**One-line summary:** Wave A closed the silent-failure + search-generation defects. Next is **concrete-value work** — D4 (per-copy perf) or the Load ADR (D0) / dead-subtree (E4) decisions — **not** the hollow UIEffectPort (reverted 2026-07-10). Structural decoupling of History↔AppState waits for a real projection split (inversion), not a singleton-wrapping port.
