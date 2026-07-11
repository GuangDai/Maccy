# 2026-07-10 Master Roadmap — the complete path after Wave A

| Field | Value |
|-------|-------|
| **Role** | The single forward-looking roadmap: what to do after Wave A, in order, with dependencies and decision forks. Supersedes the design-audit playbook (`2026-07-09-design-structure-audit/19-master-playbook.md`) priority order using the verification's recalibration + Wave A completion. |
| **Baseline** | post-Wave-A master (HEAD after `7fb08bd` / docs through `bfcf671`). |
| **Inputs** | [`2026-07-09-design-audit-verification/`](2026-07-09-design-audit-verification/) (verified findings + 19 new issues), [`2026-07-09-design-structure-audit/19-master-playbook.md`](2026-07-09-design-structure-audit/19-master-playbook.md) (waves), [`../2026-06-27-memory-floor-and-retention/`](2026-06-27-memory-floor-and-retention/) (memory track). |
| **History-split detail** | B0 frozen in [`2026-07-10-history-split-plan/`](2026-07-10-history-split-plan/): **defer split**; D4 measure-first; DS-022-standalone hollow; SwiftLint policy audit. Prefer that suite over Wave B table rows when they conflict on sequencing. |
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

**Post-roadmap progress (through 2026-07-12):** D4 (`9c8728c`), D6 (`947f88b`), D5 (`592bae6` + `01493f9`), D0 (`7852ea8`), E4 (`9849d00`), C1 (`7da8ac6` + `2ac325f`), all of C2 (`c6afcbe`, `10f8d90`, `f9f0e85`), C5 (`76a2a53` + generated project `b49b462`), C6 (`1393143`), E1 (`cd368ea`), E2 (`2a06a58`, `72fa8f2`, `9e54d77` + generated project `19b7431`), E3 (`32320cf`), and timestamp hygiene (`91d76b8`) are complete. XcodeGen M0–M3 is complete through `94ca913`: production project output is generated, and normal CI/release enforce repeatability + zero drift.

**What remains:** structure debt (the deferred god-object split), load/memory work beyond the completed D0/D4–D6 steps, single search-engine/domain cleanup, package organization, and progressive dependency injection.

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
| B0 | **History split design** (doc-only) | DS-001 | S | — | **DONE** → [`2026-07-10-history-split-plan/`](2026-07-10-history-split-plan/): **defer** file/type split; D4-first (measure); DS-022 not standalone; forcing-gate in plan `07`. |
| B1 | **UIEffectPort (DEFERRED — tried & reverted 2026-07-10)** | DS-007 | — | — | A protocol+adapter that wraps `AppState.shared` only *relocates* the coupling — the adapter still calls `AppState.shared` in every method, so runtime is unchanged and testability isn't unblocked ("脱裤子放屁"). The real fix is **inversion** (History publishes effect intents; UI subscribes), which belongs with the projection split (B2), not a standalone port. Defer. |
| B2 | **History file split** (no behavior) | DS-001, DS-022 | M–L | M | One file per commit (`refactor(history): split … no behavior change`). Also routes all store IO through one port (closes the dual persistence channel). Order: Legacy → Search → Reconcile → Mutations. |
| B3 | **Migrate tests off `add`** | DS-003 | M–L | M | `seedViaConsume` helper; quarantine sessionLog-only tests. 45 `history.add` call sites across 5 test files. |
| B4 | **Remove/isolate legacy `add`** | DS-003, DS-016 | M | M | After B3. Delete `MainActorIngestorAdapter.ingest` (fully dead). |
| B5 | **Centralize generation chokepoint** | (Wave A TODO) | S | L | Fold the `invalidateInFlightSearch()` calls (now in 6 sites) into one "any list mutation cancels in-flight search" entry point. Structural fix for the bug class Wave A patched per-site. |

### Wave C — Domain consistency (after B2 for History-touching items)

| # | Step | Closes | Effort | Risk |
|---|------|--------|--------|------|
| C1 | **Single filter source — done** (`2ac325f`) | DS-008, `NEW-clipboard-filter-1/2/3` | M | M | Shared `IngestFilter` rules now own the UTI policy; dead Clipboard helpers/cascades and doc rot were removed. |
| C2 | `SignatureIndex` consistency | DS-009 | M | M | **DONE.** C2.1 (`c6afcbe`): UI delete/clear batches actor removal/reset. C2.2 (`10f8d90`): one DTO signature projection. C2.3 (`f9f0e85`): search is read-only; backfill occurs inside the ingest transaction. Original cross-ingest timing claim refuted by `ModelContext.transaction` semantics. |
| C3 | Single `MatchEngine` + empty short-circuit | DS-010, DS-012, DS-029 | M | M | Merge legacy `Search` (217 LOC) into `SearchActor`; O(1) decorator-id resolve (`[UUID: HistoryItemDecorator]`); pin the one-item corpus-lag. |
| C4 | Batch limit deletes | DS-014 | S | M | One transaction for `limitHistorySize` trim (matches the actor's batched trim). |
| C5 | **Pin query off the entity — done** (`76a2a53`, `b49b462`) | DS-015 | S | L | Context-injected `PinService` owns supported/assigned/free-key policy; `HistoryItem` has no persistence query or `Storage.shared` access. |
| C6 | **Stored identity — done** (`1393143`) | DS-019; sharpens DS-005 | M | L | Uses Apple's stable, `Hashable`/`Sendable` `PersistentIdentifier.ID` directly; deletes string/FNV projection and avoids a redundant schema column. |

### Wave D — Read & hot paths (perf; ties to BS-4/6 memory)

| # | Step | Closes | Effort | Risk |
|---|------|--------|--------|------|
| D0 | **Load ADR — done** (`7852ea8`) | DS-004, `NEW-storage-load-models-1` | S | — | Keep the loader/background APIs test-only; production claims were removed. This records the current decision without pretending the larger DS-004 memory problem is fixed. |
| D1 | Implement the load decision | DS-004 | L | H | Windowed load (or confirmed deletion). The big memory win — unbounded `load` faults the whole table into `mainContext`. Needs memory-suite literacy. |
| D2 | **Shrink the MainActor hop — done** (`a487276`, `70e1d23`) | DS-011 | M | M | `Clipboard` attaches a live Sendable policy snapshot; pure filtering and file/plain/image projection stay on the ingest actor; fixture-backed routing keeps only selected small RTF/HTML parsing on `MainActor`. |
| D3 | Ingest coalesce | DS-020 | M | M | Product decision: latest-wins mailbox vs current one-Task-per-changeCount. |
| D4 | **`syncAllToStore` O(n)→O(deleted) — done** (`9c8728c`) | `NEW-history-spine-2` | M | M | Ingest returns deleted persistent IDs and main applies only those removals. |
| D5 | **Bound per-copy trim fetch — done** (`592bae6`, `01493f9`) | `NEW-ingest-dualpath-1` | M | M | Count + bounded tail fetch replaces full unpinned-row fault/sort on the no-trim path. |
| D6 | **Defaults reload uses reconcile — done** (`947f88b`) | `NEW-history-spine-1` | S | L | `loadAfterDefaultsChange` reuses reconcile/decorators rather than forcing full load/redecode. |

### Wave E–F — Boundaries & hygiene (low-risk, interleaves anywhere)

| # | Step | Closes | Effort | Risk |
|---|------|--------|--------|------|
| E1 | **Intent port — done** (`cd368ea`) | DS-018, `NEW-singletons-intents-misc-2/3` | M | L | `HistoryCommandService` is the single Intent application port; one resolver owns 1-based bounds and indexes `all`, not search-filtered `items`. |
| E2 | **Package moves — done** (`2a06a58`, `72fa8f2`, `9e54d77`, `19b7431`) | DS-026, DS-032, DS-034 | M | L | `Application/` owns lazy composition + DEBUG hooks + delegate/entry; all four `Search*` sources are colocated under `Search/`; full generated matrix/package green. |
| E3 | **Clipboard Timer — done** (`32320cf`) | DS-024 | S | L | Effective interval retains its 100 ms floor, adds tested 10% tolerance, and runs in `.common`. |
| E4 | **Dead paste-stack subtree deleted** (`9849d00`) | DS-028, `NEW-singletons-intents-misc-1` | S | L | Removed the unreachable model/views/state/key branches and always-false gate. |
| E5 | Progressive DI vs `shared` | DS-006 | ongoing | M | Stop new `*.shared` call sites; inject at boundaries. 175 occurrences / 26 files — whittle, don't big-bang. |

### 3.5 Hard dependencies

```text
B0 → B1 → B2 → (B3 → B4)              # structure spine; B5 after B2
D0 → D1                                # load ADR gates the load rewrite
B2 before C3/C4 (they edit the split History); C2 completed safely before the deferred split
C6 complete (`1393143`); D4/D5 pair with BS-4/6 memory work
```

---

## 4. The 19 verification-found issues → wave mapping

| New ID | Sev | Wave | Status |
|--------|-----|------|--------|
| `NEW-dedup-ids-1` | Med (top) | **A** | ✅ done |
| `NEW-history-spine-1` Defaults-reload full load | Med | D6 | ✅ done (`947f88b`) |
| `NEW-history-spine-2` syncAll O(n)/copy | Med | D4 | ✅ done (`9c8728c`) |
| `NEW-history-spine-3` load no gen bump | Low | **A** | ✅ done |
| `NEW-history-spine-4` select no invalidate | Low | **A** | ✅ done |
| `NEW-ingest-dualpath-1` commit O(n)/copy | Med | D5 | ✅ done (`592bae6`, `01493f9`) |
| `NEW-ingest-dualpath-2` read mutates candidates | Low | C2.3 | ✅ done (`f9f0e85`) |
| `NEW-ingest-dualpath-3` adapter fully dead | Low | B4 | open (B4 removes it) |
| `NEW-ingest-dualpath-4` result discarded | Low | **A** | ✅ done |
| `NEW-dedup-ids-2` findDuplicate re-derives signature | Low | C2.2 | ✅ done (`10f8d90`) |
| `NEW-dedup-ids-3` backfill cross-ingest commit | Low | C2.3 | ✅ refuted timing; coupling removed (`f9f0e85`) |
| `NEW-clipboard-filter-1/2/3` dead helpers + doc rot | Low | C1 | ✅ done (`2ac325f`) |
| `NEW-storage-load-models-1` dead newBackgroundContext + false doc | Med | D0 | ✅ ADR/docs done (`7852ea8`; APIs retained test-only) |
| `NEW-storage-load-models-2` init self-assigns timestamps | Low | C (hygiene) | ✅ done (`91d76b8`) |
| `NEW-singletons-intents-misc-1` dead paste-stack subtree | Med (cleanup value) | E4 | ✅ done (`9849d00`) |
| `NEW-singletons-intents-misc-2/3` intent dup + filtered-index ambiguity | Low/Med-Low | E1 | ✅ done (`cd368ea`) |

---

## 5. Decision forks (resolved and remaining)

1. **D0 — Load: CLOSED** — keep the loader/background APIs test-only and correct the false production docs (`7852ea8`). DS-004's larger production load/memory work remains separate.
2. **E4 — Dead paste-stack / multi-select subtree: CLOSED** — delete it (`9849d00`).
3. **B0 — History split granularity:** ~~the full 5–7 types, or a smaller first cut?~~ **CLOSED** — defer split entirely until forcing-gate; see [`2026-07-10-history-split-plan/`](2026-07-10-history-split-plan/).
4. **C6 — Stored identity: CLOSED** — use `PersistentIdentifier.ID` directly (`1393143`). It supplies the stable, store-scoped, `Hashable`/`Sendable` identity the index needs; neither the undocumented string fold nor a redundant UUID column remains.
5. **C2.1 — SignatureIndex delete-sync:** ~~`noteRemoved`, dirty-rebuild, or unified events?~~ **CLOSED** — successful UI mutations send batched `.removed`/`.cleared` events to the actor; full clear forces a safe next-ingest rebuild (`c6afcbe`).
6. **D3 — Ingest coalesce:** latest-wins mailbox, or keep one-Task-per-change (accept storm cost)?

---

## 6. Near-term plan (the next 3–5 concrete moves)

1. ~~D4/D5/D6 hot-path fixes~~ — **done** (`9c8728c`, `592bae6` + `01493f9`, `947f88b`).
2. ~~Resolve D0 and E4~~ — **done** (`7852ea8`: keep loader test-only/correct docs; `9849d00`: delete dead paste-stack subtree).
3. ~~C1 and C2.1 domain cleanup~~ — **done** (`2ac325f`, `c6afcbe`).
4. ~~C2.2 — stop re-deriving incoming signature entries~~ — **done** (`10f8d90`; shared `signatureDTO(of:)`).
5. ~~C2.3 — isolate lazy fingerprint backfill persistence semantics~~ — **done/refined** (`f9f0e85`; cross-ingest timing refuted, read-side mutation removed).
6. ~~E1 — route App Intents through a stable full-history command port~~ — **done** (`cd368ea`; duplicated 1-based bounds removed, no `AppState.shared` remains under `Intents`).
7. ~~E3 — keep clipboard polling coalescible and active during event tracking~~ — **done** (`32320cf`; tested tolerance + `.common`).
8. ~~Remove `HistoryItem.init` timestamp self-assignments~~ — **done** (`91d76b8`; no behavior change, full matrix green).
9. ~~XcodeGen M2 semantic CI equivalence~~ — **done** (`fc29202`; generated target IDs/test plan, all five generated-project shards, and Release package dry-run green in `29146217892`).
10. ~~XcodeGen M3 production cutover~~ — **done** (`94ca913`; generated output committed, manual full matrix `29153231827`, master generation+test gate `29153606508`, release dry-run `29153818821`).
11. ~~C5 — move pin availability queries off `HistoryItem`~~ — **done** (`76a2a53`, `b49b462`; context-injected module, generated-project full matrix + Release package green in `29154584664`; C3/C4 still respect the documented B2 dependency).
12. ~~E2 — organize Application/Search packages~~ — **done** (`2a06a58`, `72fa8f2`, `9e54d77`, `19b7431`; generated-project full matrix + Release package green in `29167115880`; B2-gated work stays gated).
13. ~~C6 — settle stored item identity~~ — **done** (`1393143`; Apple-documented stable ID, no schema, string/FNV projection deleted; full matrix green in `29167878876`).
14. ~~D2 — shrink the ingest MainActor hop~~ — **done** (`a487276`, `70e1d23`; request policy snapshot + pure routing plan; heavy plain-text fixture requires no main work, RTF stays safely main-affine; full generated matrix green in `29168784563`). Next: D3.

XcodeGen M4 is now an ongoing invariant rather than a separate migration track.

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

**One-line summary:** Wave A plus D0/D2/D4–D6, C1/C2/C5/C6, E1–E4, and XcodeGen M0–M3 are complete. Next is D3; C3/C4 remain behind their documented B2 dependency, while History↔AppState structural decoupling waits for a real projection forcing gate—not a singleton-wrapping port.
