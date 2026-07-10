# 2026-07-10 — History Split Grilling: B0 Decision (defer split; D4-first; measure-first)

| Field | Value |
|-------|-------|
| **Role** | The B0 (History split design) decision record (short form). Output of a `/grill-with-docs` session (grilling + domain-modeling). Supersedes the open B0 fork in [`../2026-07-10-master-roadmap.md`](../2026-07-10-master-roadmap.md) §5 #3. **Expanded authority:** [`../2026-07-10-history-split-plan/`](../2026-07-10-history-split-plan/) (SwiftLint forensics, anatomy, D4 design, execution board, claim corrections). |
| **Method** | (1) Firsthand read of `History.swift` (978 LOC), `HistoryPersistence.swift`, the B1 revert (`bfcf671`), and the verification findings. (2) A 4-judge adversarial workflow (`_workflow-history-split.js`): 4 independent proposals (minimal-gate-clearer / value-bundler / depth-extractor / roadmap-skeptic), each attacked by a skeptic on the B1 hollow-ness test. (3) Firsthand verification of every load-bearing claim against HEAD. |
| **Baseline** | post-Wave-A master (HEAD after `7fb08bd`); `History.swift` = 978 LOC. |
| **Constraint honored** | "Avoid any surface / ineffective / meaningless work." The B1 lesson: a structural change must deliver concrete value (correctness / measured perf / a test actually unblocked / a hard gate cleared), not relocate coupling. |

---

## 1. The decision

1. **Defer the History split.** Do not split `History.swift` now.
2. **The next concrete step is D4** (`syncAllToStore` O(rows)→O(deleted) per copy) — **gated by a measurement** (push a per-copy@n=1000 perf test, read the CI baseline before scoping D4).
3. **DS-022-close is NOT a standalone step.** Routing the 5 direct `Storage.shared.context` sites through `HistoryPersistence` on its own is hollow-as-B1 (see §3). It folds into a *later* B2 split (where relocating the IO is justified because the split simultaneously cures the `file_length` wall), or into D1 (where a fake intercepts a real windowed path). Never standalone.

---

## 2. Why splitting now is hollow-or-premature (verified)

- **The lint wall is green.** `History.swift` = 978; `.swiftlint.yml` `file_length`/`type_body_length` error = 1000. 22 lines of headroom. SwiftLint **excludes** `extension` declarations from `type_body_length` by default (`excluded_types: [extension, protocol]`; the project doesn't override it — CI runs stock `brew install swiftlint`) and counts `file_length` per physical file, so moving methods into `extension History {}` in another file shrinks both the measured class body and the file — clearing both gates without new types. **The lint wall does not force real type extraction, and does not distinguish hollow from concrete.** (Mechanism corrected per [`../2026-07-10-history-split-plan/02-swiftlint-policy-audit.md`](../2026-07-10-history-split-plan/02-swiftlint-policy-audit.md) §2; this suite's conclusion is affirmed, cross-validated by that plan's independent firsthand + git-forensic pass.)
- **D4 *shrinks* the file** (`syncAllToStore` ~33 LOC → ~targeted removal), so the next planned change buys headroom, not consumes it.
- **The C-wave (C1/C2/C3/C4) that would need headroom is not imminent**, and is itself gated on B2 — but B2 is what we're deferring.
- **Real type extraction is dominated until D1.** `@Observable` does not compose trivially: extracting observed state (`searchQuery`/`items`/`all`/`lastPersistError`) into a subtype breaks SwiftUI view observation unless the subtype is itself `@Observable` and re-exposed. The one subtype whose state is *not* observed (`all`, `@ObservationIgnored`) is `StoreProjector` — and it only earns its boundary once D1 windowed-load gives it a second job (owning `all` + IO + the window).

The 4-judge panel **converged 3-of-4** on this (minimal-gate-clearer, depth-extractor, roadmap-skeptic). The depth-extractor *started* wanting real extraction and was forced by the evidence to concede it is dominated until D1. The one lens that said "split now" (value-bundler) was the **only one ruled hollow** by its skeptic.

---

## 3. The key finding: closing DS-022 standalone is hollow-as-B1 (verified)

The roadmap (and the author's first synthesis) treated "route the 5 direct `Storage.shared.context` sites through `HistoryPersistence`" as the one structural change with standalone concrete value. **It is not.** Verified against HEAD:

- **No correctness fix.** All 4 live sites already handle errors correctly: `load()`@210 throws→`loadAndRecordError`; `reconcileWithStore`@434 / `syncAllToStore`@403 do/catch→`recordPersistenceError`; `insertIncrementally`@337 non-throwing `model(for:)`→guard→fallback. Routing through the port closes no swallow bug.
- **No measured perf.** Byte-identical runtime (`fetchAll` delegates to the same `Storage.fetch`; `fetchIdentifiers`/`resolve` would be new wrappers over the same calls).
- **No test unblocked today.** `load()` and `syncAllToStore()` failure paths are **already tested** via the DEBUG force-failure seams — `HistoryConsumeTests.swift:196` (`setSyncAllFetchFailureForTesting`) and `:224` (`setLoadFailureForTesting`). The `FailingHistoryPersistence` double (`IngestErrorPropagationTests.swift:48`) throws only on `insert`/`deleteUnpinned`; its `fetchAll` returns empty. So the testability gain is **redundant for the two tested paths, hypothetical for the two untested** (`reconcileWithStore`, `mergeDuplicateIfNeeded`).
- **Relocates coupling, like B1.** `SwiftDataHistoryPersistence` wraps `Storage.shared.context` in *every* method. Routing the 5 sites through the port moves the call `History → port → impl → Storage.shared` — the same shape as B1's `History → port → adapter → AppState.shared`. "It's an *existing* port" makes it less egregious than B1, not more valuable; runtime is identical and the wrapper still calls the singleton.

**Therefore:** DS-022-close earns its keep only inside B2 (where the IO relocation is justified by simultaneously curing the `file_length` wall) or D1 (where a fake intercepts a real windowed path on arrival). Standalone, it is enabling-structure dressed as value — the exact shape B1 was reverted for.

---

## 4. D4 design (when the measurement justifies it)

The clean DTO route the panel missed: **widen the `onEvent` callback, not `StoreEvent` and not `IngestResult`.**

- `consume`'s only prod caller is `AppDelegate.swift:86` (`onEvent: { event in History.shared.consume(event) }`), set on the actor at init as `@Sendable (StoreEvent) async -> Void` (`ClipboardIngestor.swift:98,148,242`).
- Widen to `@Sendable (StoreEvent, [PersistentIdentifier]) async -> Void`. **`PersistentIdentifier` is Sendable** — proven: `ItemSnapshotDTO: Sendable` (`Dtos.swift:73`) already carries `persistentID: PersistentIdentifier?` (`:81`).
- `commit()` (`ClipboardIngestor.swift:455-487`) already has the deleted `@Model` refs in hand before `context.delete` — capture `dup.persistentModelID` + each `excess[i].persistentModelID` there (alongside the existing `[ItemID]` dedup-index return).
- `consume(_ event:, trimmedPersistentIDs: [PersistentIdentifier] = [])` — **defaulted**, so all existing `consume(.added(snapshot))` test calls are untouched, and the `StoreEvent` enum + its ~32 construction sites (DtoTests, SignatureIndexTests, HistoryConsumeTests…) are **completely untouched**.

**Correctness detail (flagged by the panel, verified):** the `.merged` dup's decorator is removed *only* by `syncAllToStore` today — `insertIncrementally`@329 matches decorators whose `persistentModelID == persistentID` (the *new* merged id, post-insert), which can never match the *deleted* dup. So the D4 fast path **must** include the dup's `persistentModelID` in the trimmed set (it is — `commit()` deletes `dup`). Keep `syncAllToStore`/`reconcileWithStore` as the fallback for `.removed`/`.cleared` and the nil-persistentID / `model(for:)`-miss paths.

**Churn:** ~5 prod sites (`onEvent` type, actor call site `:242`, AppDelegate closure `:86`, `consume` signature, `commit` return). No enum churn. No test-construction churn. This is far smaller than the panel's "change `StoreEvent`, ~32 sites" framing.

---

## 5. Measure-first protocol

1. **Commit: a per-copy perf test at n=1000** in the existing perf harness (the 4.4a harness measures the full `consume(.added)` path; `syncAllToStore` is the slice D4 removes). `feat(d4): add per-copy@n=1000 perf baseline`. Push; read the CI `perf-text` shard.
2. **Interpret the baseline:**
   - **> ~100µs/copy contribution from `syncAllToStore`:** D4 is a perf win (two-fer: perf + deletes one DS-022 site). Proceed with D4 as scoped in §4.
   - **< ~20µs:** stop calling D4 a perf win. Its value reduces to "delete one of five DS-022 sites + D1 prerequisite." **Cascade → resolve D0 (Load ADR) first** (see §7); D4 is worth doing only if D1 is near-term.

The perf test stays as a reusable regression gate regardless of outcome.

---

## 6. The split forcing-gate (when the deferred split actually fires)

**Gate:** the lint wall is tripped by a real addition **OR** D1 windowed-load is green-lit **OR** B5 (generation-chokepoint) restructures the search methods.

When it fires, in order:
1. **If legacy `add` is still present → do B3+B4 first** (migrate tests off `add`, then delete the ~80 LOC dead legacy path + the fully-dead `MainActorIngestorAdapter.ingest`). This is permanent headroom + dead-code cleanup — **no split needed.** (The wall is 22 over; deleting ~80 buys large headroom.)
2. **Else, if the wall still trips → extension-split the Reconcile cluster** (`consume`/`insertIncrementally`/`syncAllToStore`/`reconcileWithStore`) into `History+Reconcile.swift`. It is the `StoreProjector`/D1 candidate and is stable post-D4. **Never split Search first** — `invalidateInFlightSearch`@937 lives in the Search cluster and B5/the `searchGeneration` bug-class (the single most active fix source) would rebase against the move.
3. **If D1 is the trigger → real `StoreProjector` extraction.** The one place real-type-extraction is justified: it owns `all` (`@ObservationIgnored` → no observation cost) + IO + the window. One type per PR; never the 5–7-type migration (red line).

---

## 7. Cascade: if the measurement is negligible → D0 (Load ADR)

If `syncAllToStore`@n=1000 is already cheap, D4's headline value doesn't materialize, and its residual value (one DS-022 site + D1 prerequisite) is only worth a PR if **D1 is near-term**. D1 is gated on the unresolved **D0 Load ADR** ([master-roadmap §5 #1](../2026-07-10-master-roadmap.md)): wire `VisibleWindowLoader`, delete it, or keep test-only + fix the false "production calls this" docstring. So: **unfavorable measurement → decide D0 next**, not D4.

---

## 8. Red lines respected

No EventBus; no search index without measured need; no repository pyramid; no full DDD package tree in one migration; **structure ≠ behavior in the same PR** (D4 is behavior → own PR; the perf test is its own commit; DS-022-close folds into a later B2/D1, never standalone); no dirs+dedup+load in one PR; no `mainContext.reset()`; the post-hash `==` and the ingest single transaction are untouched.

## 9. What this does NOT do

- Does not split `History.swift` now (deferred per §6 gate).
- Does not touch the 22 `AppState.shared` sites (that is B1/inversion — `History` publishes effect intents, UI subscribes — explicitly deferred and never a singleton-wrapping port).
- Does not decide D0/E4 (separate roadmap forks; D0 enters only via the §7 cascade).

---

**One-line summary:** B0 decided — **defer the split; D4 next via a measure-first perf commit; the clean D4 route widens `onEvent` (not `StoreEvent`, ~5 sites); DS-022-close is hollow-as-B1 standalone and folds into a later B2/D1; the split fires on lint-wall/D1/B5, answered first by deleting the dead legacy `add`.**

---

## 10. S1 measured baseline (CI run `29056900573`, branch `d4-measure-baseline`, commit `71dee34`)

CI green (all 6 jobs). The `perf-text` shard printed both `G-copy` lines in one run (directly comparable):

| | per-copy avg | per-copy max | mainThread maxGap |
|---|---|---|---|
| n=200 (existing `testGCopyPerCopyConsume_N200`) | 2.00 ms | 4.65 ms | 0.259 s |
| n=1000 (new `testGCopyPerCopyConsume_N1000`) | 6.50 ms | 15.03 ms | 0.358 s |
| growth for 5× items | **3.25×** | 3.23× | 1.38× |

**Verdict: D4 is a GO.** Cost scales with n and is material at n=1000 (6.50 ms avg ≫ ~100 µs threshold; n=200→1000 grows 3.25×, not flat). **Caveat:** 6.50 ms is the whole `consume(.added)` path — several O(n) pieces per copy (`all.firstIndex`, `all.insert`, `syncAllToStore`, `refreshVisibleItems`); D4 removes only the `syncAllToStore` slice (full-table `fetchIdentifiers` + scan — the most clearly removable; the actor already has the deleted set; the only piece that crosses to SwiftData per copy). The before/after on implementing D4 reveals its exact fraction; the test stays as the regression gate. If the drop disappoints, reassess — residual value (one DS-022 site deleted + D1 prep) stands either way.

---

## 11. D4 result (CI run `29058652343`, commits `9c8728c` + `f04d1f9`)

D4 landed CI-green (all 6 jobs) on branch `d4-measure-baseline`. Implementation: widen `onEvent` to `(StoreEvent, [PersistentIdentifier])`; `commit()` captures `dup`/`excess` `persistentModelID` before delete; `consume(_:trimmedPersistentIDs:)` → `removeDecorators` (O(deleted)); **`syncAllToStore` removed entirely** (empty-trimmed is a no-op — the win on the common plain-copy path; `reconcileWithStore` remains the guard-failure fallback). History.swift net **−21 LOC** (978→957).

**Measured before → after (the `perf-text` G-copy gate):**

| | per-copy avg | per-copy max | mainThread maxGap |
|---|---|---|---|
| n=200: 2.00 → **0.75 ms** | **−62 %** | 4.65 → 1.02 | 0.259 → 0.114 s |
| n=1000: 6.50 → **3.33 ms** | **−49 %** | 15.03 → **4.51 (−70 %)** | 0.358 → 0.246 s |

`syncAllToStore`'s slice = **~3.2 ms/copy at n=1000** (+ the 15 ms max spike) — exactly the fraction §10 predicted. **D4 is validated as a measured perf win**, and it also deletes one DS-022 site (the `fetchIdentifiers`) and preps D1 (the consumer now trusts actor-reported deletes — the model windowed-load extends).

**What D4 did NOT fix (honest):** the remaining n=1000 cost (3.33 ms) and its scaling (n=200→1000 still grows ~4.4×) come from the *other* O(n) pieces — `all.firstIndex` (find-existing scan), `all.insert` (array shift), `refreshVisibleItems` (`items = all` copy + shortcuts). Those are separate concerns (not D4). The actor-side O(n) wall — `commit()` fetches+sorts all unpinned rows every copy — is **D5** (`NEW-ingest-dualpath-1`), the natural pair to D4.

**One design correction made during implementation:** the plan's "policy A+C" (empty-trimmed → `syncAllToStore` fallback) was **wrong** — it would have left the O(rows) fetch running on every empty-trim copy (the common case), defeating D4. Corrected to "empty → no-op," which is what forced `syncAllToStore`'s removal (and cleared `file_length`).

**Test-contract note:** two existing `HistoryConsumeTests` (merge / size-trim) simulated the actor but relied on `syncAllToStore` for orphan cleanup; updated to pass the `trimmedPersistentIDs` the production actor always supplies (assertions unchanged). `f04d1f9`.

**Status:** branch `d4-measure-baseline` (3 commits: `71dee34` baseline, `9c8728c` D4, `f04d1f9` test fix) is CI-green and ready to merge to master.

---

## 12. D6 landed + D5 measure finding (commits `947f88b`, `bd49ff3`; master CI green)

- **D6 landed** (`947f88b`, merged to master): `loadAfterDefaultsChange` → `reconcileWithStore` (+ `invalidateInFlightSearch`) — a Settings sort/pin toggle no longer discards decoded images.
- **D5 measure-first** (`bd49ff3`, `testGIngestPerCopy_N1000`, CI run `29061409815`, all green): the ingest actor's per-copy cost at n=1000 is **51.90 ms avg / 83.93 ms max** (`mainThread_maxGap` 0.080 s → ~48 ms is OFF-main, in `commit()`'s full-row fetch+sort of all unpinned rows every copy). **This overturns the "D5 is off-main/ignorable" assumption** — at n=1000 a copy takes ~55 ms total (52 actor + 3.3 main), and copy storms compound. D5 is HIGHLY justified; the cost is the full-row *faulting* (D4's `fetchIdentifiers` was ids-only/cheap; this `fetch` faults 1000 `@Model`s).
- **D5 implementation risk:** `commit()`'s trim logic is correctness-critical (eviction = potential data loss), and the actor gets **no notification of main-side pin changes** → an incremental/in-memory "tail" could evict a just-pinned item. A design+verify workflow (`_workflow-d5-design.js`) is evaluating 3 approaches (incremental-tail / bounded-fetch / minimal-or-defer) against the trim invariants + pin-drift before any code change.

---

## 13. D5 landed — per-copy O(n) story closed (commits `592bae6` + `01493f9`; master)

The D5 design workflow (`_workflow-d5-design.js`, 6 agents) **converged**: all 3 lenses picked **bounded-fetch** (`fetchCount` no-fault + `fetchLimit` tail), and the **incremental in-memory tail was rejected as hollow (B1)** — once pin-safety forces per-candidate revalidation via `fetchLimit`+predicate, the in-memory structure is 100% redundant and only adds a drift surface. One verifier's refinement: delete the dup (pending) *before* the fetches so both honor the live `pin == nil` predicate and exclude it (no dup flag, no arithmetic subtraction, no cached-fault divergence).

**Implemented** (`592bae6` + compile-fix `01493f9`): `commit()`'s transaction body now does `delete(dup)` (pending) → `fetchCount(pin==nil)` (no-fault SQL COUNT, excludes the pending dup) → `fetchLimit`-bounded read of only the oldest `toEvict` rows (steady-state ~1) → `insert`. Single transaction + single save preserved; no in-memory state; predicate fresh per copy → **provably cannot evict a pinned item**.

**Measured (CI run `29063084679`, perf-text, all 6 jobs green):** actor ingest per-copy at n=1000 = **51.90 → 4.40 ms avg (−91.5%, 11.8×), max 83.93 → 6.04 ms**, `mainThread_maxGap` 0.080 → 0.004 s. The dup-before-count test + existing trim tests + the new `testCommitDoesNotEvictPinnedItemWhenTrimming` (data-loss guard) all pass → `fetchCount` honors the pending dup-delete inside the transaction, and pin-exclusion works.

**Per-copy O(n) at n=1000 is now closed:** D4 (main) 6.50→3.33 ms + D5 (actor) 51.90→4.40 ms ⇒ **total per-copy ~55 ms → ~8 ms**. The residual ~4.4 ms (actor) + ~3.3 ms (main) is the floor (MainActor hop, `model(for:)`, binary insert, corpus update, save, `refreshVisibleItems`) — not O(rows) fetches.




