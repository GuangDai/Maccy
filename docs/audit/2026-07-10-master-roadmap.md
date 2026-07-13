# 2026-07-10 Master Roadmap — the complete path after Wave A

| Field | Value |
|-------|-------|
| **Role** | The single forward-looking roadmap: what to do after Wave A, in order, with dependencies and decision forks. Supersedes the design-audit playbook (`2026-07-09-design-structure-audit/19-master-playbook.md`) priority order using the verification's recalibration + Wave A completion. |
| **Baseline** | post-Wave-A master (HEAD after `7fb08bd` / docs through `bfcf671`). |
| **Inputs** | [`2026-07-09-design-audit-verification/`](2026-07-09-design-audit-verification/) (verified findings + 19 new issues), [`2026-07-09-design-structure-audit/19-master-playbook.md`](2026-07-09-design-structure-audit/19-master-playbook.md) (waves), [`../2026-06-27-memory-floor-and-retention/`](2026-06-27-memory-floor-and-retention/) (memory track). |
| **History-split detail** | B0's original defer decision remains the historical baseline in [`2026-07-10-history-split-plan/`](2026-07-10-history-split-plan/). The gate later fired through B3/B4 deletion, B5's mutation chokepoint, and C3's independently testable search boundary; B2–B5 are complete on `b2-b5-history`. |
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

**Post-roadmap progress (through 2026-07-13):** D4 (`9c8728c`), D6 (`947f88b`), D5 (`592bae6` + `01493f9`), D0 (`7852ea8`), D1 (measured no-go + confirmed deletion; run `29176185359`), E4 (`9849d00`), C1 (`7da8ac6` + `2ac325f`), all of C2 (`c6afcbe`, `10f8d90`, `f9f0e85`), C5 (`76a2a53` + generated project `b49b462`), C6 (`1393143`), E1 (`cd368ea`), E2 (`2a06a58`, `72fa8f2`, `9e54d77` + generated project `19b7431`), E3 (`32320cf`), timestamp hygiene (`91d76b8`), dead ingest-plan DTO cleanup (DS-017/DS-031), the `HistoryItemEngine` DTO boundary (DS-030), and pending-insert-safe clear-unpinned semantics (DS-025) are complete. B2–B5 also landed as small commits: committed-store test seeding, legacy writer deletion, value UI effects, `HistoryListState`, `HistorySearchSession`, `HistoryStoreProjector`, and `HistoryMutations`. C3 removed the legacy 217-line search engine (`5fd7bf4`; full green `29205361439`); C4 batches load-limit deletes (`04ab27c`; full green `29206774668`). E5's first progressive-DI slice injects History clipboard/event/current-event/log services, makes ordinary test instances inert, and confines live `Clipboard.shared`/`NSApp` access to the `History.shared` composition factory (`c8c8fbf` + `02711cb`; full green `29210900842`). Its second slice injects AppState text-copy effects, makes prewarm use the composed History, and makes the Settings close observer mutate its owning instance instead of `AppState.shared` (`ed664b2`; full green `29211587341`). The third injects the storage-size reader into `StorageSettingsPane`, closing the last production pane access in DS-033 (`bd238fe`; full green `29212071043`). The fourth replaces Footer's five `AppState.shared` closures with closed `FooterAction` values interpreted by its owning AppState (`7d1d3e2`; full green `29212815681`). The fifth gives Navigation an immutable current-lead output composed to Preview by AppState, removing its global Preview lookup (`38ef0c9`; full green `29214579841`). The sixth makes Slideout own current lead, weak-bind its panel, and accept Popup sizing as an input (`c9f2273`). The seventh injects the main `ModelContext` into `SwiftDataHistoryPersistence`, removing its 15 method-level global reads and History's implicit live backend (`4bcfc47`). Their joint full matrix is `29215547393` (338 unit, 0 failures). XcodeGen M0–M3 is complete through `94ca913`: production project output is generated, and normal CI/release enforce repeatability + zero drift.

**What remains:** load/memory work beyond the completed D0/D4–D6 steps, framework-floor-aware retention work, and progressive dependency injection outside the now-split History spine.

---

## 2. Strategy — three themes + cleanup

The verification showed the audit's *mechanisms* were right but its *severity* was inflated. The remaining work is therefore **not** a fire drill — it's debt paydown ordered by leverage:

1. **Structure spine (Wave B, completed)** — the former 989-LOC `History` god object, ×23 `AppState` coupling, dual writer, and dual persistence channel were decomposed/deleted behind fake-backed seams. Preserve those boundaries rather than rebuilding the monolith.
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
| B0 | **History split design** (doc-only) | DS-001 | S | — | **DONE/EXECUTED** → the plan first deferred hollow file surgery, then its real gate fired through B3/B4+B5/C3; completion overlay is in [`2026-07-10-history-split-plan/`](2026-07-10-history-split-plan/). |
| B1 | **Value UI-effect inversion — done** (`acd04dc`) | DS-007 | M | L | The rejected singleton-wrapping adapter stayed deleted. `HistoryUIEffect` values now leave History modules through a composition-owned sink; `AppState` interprets them without any `History → AppState.shared` edge. |
| B2 | **Deep History decomposition — done** (`27562cc`, `b8da02f`, `35365fa`) | DS-001, DS-022 | M–L | M | Real modules own list state, search session, store projection, and mutations. `History.swift` is 341 LOC after final seam cleanup; direct context IO exists only in `SwiftDataHistoryPersistence`. |
| B3 | **Migrate tests off `add` — done** (`887b2c8`…`3f27156`) | DS-003 | M–L | M | `HistoryTestDriver` seeds committed models through live `StoreEvent` projection; performance fixture population is isolated from projection (`f50cfc5`). |
| B4 | **Delete legacy writer — done** (`c53a183`, `e601eb8`) | DS-003, DS-016 | M | M | Legacy `History.add`/sessionLog writer and `MainActorIngestorAdapter` were deleted; the AppKit dependency retained only where live event handling needs it. |
| B5 | **Centralize generation chokepoint — done** (`c7f50be`) | (Wave A TODO) | S | L | `HistoryListState` owns structural mutation and invokes one search-invalidation hook; completed-search publication intentionally bypasses that hook. |

### Wave C — Domain consistency (after B2 for History-touching items)

| # | Step | Closes | Effort | Risk |
|---|------|--------|--------|------|
| C1 | **Single filter source — done** (`2ac325f`) | DS-008, `NEW-clipboard-filter-1/2/3` | M | M | Shared `IngestFilter` rules now own the UTI policy; dead Clipboard helpers/cascades and doc rot were removed. |
| C2 | `SignatureIndex` consistency | DS-009 | M | M | **DONE.** C2.1 (`c6afcbe`): UI delete/clear batches actor removal/reset. C2.2 (`10f8d90`): one DTO signature projection. C2.3 (`f9f0e85`): search is read-only; backfill occurs inside the ingest transaction. Original cross-ingest timing claim refuted by `ModelContext.transaction` semantics. |
| C3 | **Single `MatchEngine` + O(1) resolution — done** (`27562cc`, `5fd7bf4`) | DS-010, DS-012, DS-029 | M | M | `HistorySearchSession` owns the actor corpus and `[UUID: decorator]` lookup; empty query publishes directly; legacy `Search.swift` and its 304-line test suite are deleted. Full matrix `29205361439`. |
| C4 | **Batch limit deletes — done** (`04ab27c`) | DS-014 | S | M | `HistoryStoreProjector.load` identifies exact unpinned overflow once, deletes it in one transaction/save, then sends one batched index-sync event. Full matrix `29206774668`. |
| C5 | **Pin query off the entity — done** (`76a2a53`, `b49b462`) | DS-015 | S | L | Context-injected `PinService` owns supported/assigned/free-key policy; `HistoryItem` has no persistence query or `Storage.shared` access. |
| C6 | **Stored identity — done** (`1393143`) | DS-019; sharpens DS-005 | M | L | Uses Apple's stable, `Hashable`/`Sendable` `PersistentIdentifier.ID` directly; deletes string/FNV projection and avoids a redundant schema column. |

### Wave D — Read & hot paths (perf; ties to BS-4/6 memory)

| # | Step | Closes | Effort | Risk |
|---|------|--------|--------|------|
| D0 | **Load ADR — done** (`7852ea8`) | DS-004, `NEW-storage-load-models-1` | S | — | Keep the loader/background APIs test-only; production claims were removed. This records the current decision without pretending the larger DS-004 memory problem is fixed. |
| D1 | **Load decision implemented — measured no-go + deletion** | DS-004 | — | — | Complete-history store sorting was only ~1% faster (34.202 vs 34.551 ms, run `29176185359`), inside noise. Windowing has ~0 memory value and breaks complete search, so it was rejected; obsolete loader/context test scaffolding was deleted. |
| D2 | **Shrink the MainActor hop — done** (`a487276`, `70e1d23`) | DS-011 | M | M | `Clipboard` attaches a live Sendable policy snapshot; pure filtering and file/plain/image projection stay on the ingest actor; fixture-backed routing keeps only selected small RTF/HTML parsing on `MainActor`. |
| D3 | **Lossless ingest mailbox — done** (`b754ac6`, `9fbb6e6`) | DS-020 | M | M | One FIFO drain Task per burst; at most one outstanding ingest; every observed request retained in order. Rejects latest-wins because dropping an observed copy violates clipboard-history semantics. |
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
| E5 | Progressive DI vs `shared` | DS-006, DS-033 | ongoing | M | History/AppState runtime effects are injected; storage-size reading is composed; Footer's five global closures are closed values interpreted by AppState (`7d1d3e2`, `29212815681`). Review hardening proves Storage create/refresh and every Footer interpreter case, and keys clear actions by typed value (`f84ffa1`–`a405089`, `29213836925`). Navigation publishes current lead through an immutable constructor output (`38ef0c9`, `29214579841`); Slideout owns lead/window state and injected sizing (`c9f2273`); SwiftData persistence owns an injected context instead of method-level globals (`4bcfc47`); joint full matrix `29215547393`. Continue boundary-by-boundary; don't big-bang. |

### 3.5 Hard dependencies

```text
B3 → B4 → B5 → B1/B2 → C3 → C4        # completed safe execution order
D0 → D1                                # load ADR gates the load rewrite
B2 before C3/C4; all three are now complete
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
| `NEW-ingest-dualpath-3` adapter fully dead | Low | B4 | ✅ done (`c53a183`) |
| `NEW-ingest-dualpath-4` result discarded | Low | **A** | ✅ done |
| `NEW-dedup-ids-2` findDuplicate re-derives signature | Low | C2.2 | ✅ done (`10f8d90`) |
| `NEW-dedup-ids-3` backfill cross-ingest commit | Low | C2.3 | ✅ refuted timing; coupling removed (`f9f0e85`) |
| `NEW-clipboard-filter-1/2/3` dead helpers + doc rot | Low | C1 | ✅ done (`2ac325f`) |
| `NEW-storage-load-models-1` dead newBackgroundContext + false doc | Med | D0/D1 | ✅ false claim fixed at D0; dead helper/loader deleted after D1 no-go |
| `NEW-storage-load-models-2` init self-assigns timestamps | Low | C (hygiene) | ✅ done (`91d76b8`) |
| `NEW-singletons-intents-misc-1` dead paste-stack subtree | Med (cleanup value) | E4 | ✅ done (`9849d00`) |
| `NEW-singletons-intents-misc-2/3` intent dup + filtered-index ambiguity | Low/Med-Low | E1 | ✅ done (`cd368ea`) |

---

## 5. Decision forks (resolved and remaining)

1. **D0/D1 — Load: CLOSED** — D0 corrected the false production claims; D1 then measured a behavior-equivalent alternative at only ~1% faster and rejected it. Windowing is not a sound memory lever and would degrade full-history UX, so the dead loader/context test scaffolding was deleted.
2. **E4 — Dead paste-stack / multi-select subtree: CLOSED** — delete it (`9849d00`).
3. **B0 — History split granularity: CLOSED/EXECUTED** — the original decision correctly deferred a hollow extension split. B3/B4 deletion plus B5/C3 testability later fired the real-type gate; four cohesive modules landed incrementally, not as a big-bang package tree.
4. **C6 — Stored identity: CLOSED** — use `PersistentIdentifier.ID` directly (`1393143`). It supplies the stable, store-scoped, `Hashable`/`Sendable` identity the index needs; neither the undocumented string fold nor a redundant UUID column remains.
5. **C2.1 — SignatureIndex delete-sync:** ~~`noteRemoved`, dirty-rebuild, or unified events?~~ **CLOSED** — successful UI mutations send batched `.removed`/`.cleared` events to the actor; full clear forces a safe next-ingest rebuild (`c6afcbe`).
6. **D3 — Ingest coalesce: CLOSED** — use a lossless FIFO mailbox (`b754ac6`): coalesce Task creation, not clipboard data. Latest-wins was rejected because it silently drops already-observed copies.

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
15. ~~D3 — replace one-Task-per-change with a lossless FIFO mailbox~~ — **done** (`b754ac6`, `9fbb6e6`; one drain Task per burst, no concurrent/reentrant ingest calls, no dropped requests; full generated matrix green in `29175614620`).
16. ~~D1 — measure complete-history startup alternatives~~ — **done/no-go** (run `29176185359`: 34.202 vs 34.551 ms, ~1% inside noise; no partial-history tradeoff; dead window loader/context scaffolding deleted). Next: remaining non-B2-gated work.
17. ~~B2–B5 + C3/C4 — decompose History after the real gate~~ — **done** (`c53a183`, `c7f50be`, `acd04dc`, `27562cc`, `b8da02f`, `35365fa`, `5fd7bf4`, `04ab27c`; B2d full matrix `29209334126`; final seam cleanup full matrix `29209585359`).

XcodeGen M4 is now an ongoing invariant rather than a separate migration track.

---

## 7. Red lines & over-design traps (do not)

- **Don't** weaken post-hash `==` in `dataLikelyEqual`; **don't** casual-edit the C++ UTF-8 validation; **don't** split the ingest single transaction; **don't** drop the search generation/title-equality guards; **don't** `mainContext.reset()` for memory.
- **Don't** move directories + change dedup + change load in one PR (un-bisectable).
- **Don't** build a generic `EventBus`, a search index without measured need, a repository pyramid for one SQLite aggregate, or a full DDD package tree in one migration.
- **Don't** reword log/error messages to dodge the CI self-scan — allowlist expected fault-injection logs instead (locked principle, 2026-07-09).
- **Don't** move cohesive behavior back into `History.swift`; it is now a ~341-line composition/observable facade over list, search, projection, and mutation modules.

---

## 8. Cross-cutting tracks (run in parallel, don't fight the structure work)

- **Memory / BS-4/6/8** (`2026-06-27-memory-floor-and-retention/`): the load rewrite (D1) and the per-copy O(n) fixes (D4/D5) are the Swift-side memory levers; the image-cache/blob-pool work is separate. Structure (B) *enables* clean memory fixes (e.g., a `StoreProjector` that can release decorators).
- **Docs / real-time tracking**: keep `INDEX.md` → this roadmap as the live plan; the design audit (`02`/`17`) remains the mechanism authority; the verification (`01` verdicts) the severity authority.

---

**One-line summary:** Wave A, B2–B5, C1–C6, D0–D6, E1–E4, and XcodeGen M0–M3 are complete. D1 stayed a measured no-go without sacrificing complete-history UX; the later real History gate produced cohesive list/search/projector/mutation modules, value UI effects, one persistence channel, one search engine, and batched load-limit deletion.
