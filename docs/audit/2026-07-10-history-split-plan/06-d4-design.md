# 06 — D4 Design: `syncAllToStore` O(rows) → O(deleted)

**Closes:** `NEW-history-spine-2` · **Wave:** D (master roadmap D4) · **Type:** behavior · **Baseline:** HEAD

---

## 1. Problem statement

Per copy on the live path:

```text
insertIncrementally → syncAllToStore
  → fetchIdentifiers(all HistoryItem rows)   // O(rows) store
  → scan History.all for ids not in set      // O(n) main
  → remove orphan decorators + searchActor.remove
```

At n=1000: ~1000 ids fetched + ~1000 decorators scanned **on MainActor**, every copy.

The ingest actor **already computes** the delete set (duplicate merge delete + size-trim excess) inside `commit` as `deletedItemIDs: [ItemID]` for `SignatureIndex` maintenance — but **does not ship store-level persistent IDs to main** for decorator sync.

Finding source: [`02-new-findings.md`](../2026-07-09-design-audit-verification/02-new-findings.md) `NEW-history-spine-2`.

---

## 2. Goals / non-goals

### Goals

- Apply **known** deletions to `all` in O(deleted) on the happy path.  
- Preserve full `syncAllToStore` / `reconcileWithStore` as **fallback** for `.removed`/`.cleared`, nil `persistentID`, `model(for:)` miss, title gate fail.  
- Keep **structure ≠ behavior**: D4 is behavior-only (no file split).  
- Minimize churn: **do not** expand `StoreEvent` cases if avoidable.

### Non-goals

- Fixing actor-side O(n) unpinned fetch in `commit` (that is **D5** / `NEW-ingest-dualpath-1`).  
- Closing DS-022.  
- Touching AppState.  
- Migrating tests off `add`.

---

## 3. Chosen transport: widen `onEvent` (not `StoreEvent`)

### Rejected: change `StoreEvent`

`StoreEvent` is `added/merged/removed/cleared`. Carrying a delete list on every case or a new case touches:

- enum + Equatable  
- ~many construction sites in unit tests (DtoTests, SignatureIndexTests, HistoryConsumeTests, …)  
- SignatureIndex merge logic  

### Rejected: only put deletes on `IngestResult`

`IngestResult` is for the **dispatch site** (Clipboard / AppDelegate metrics + error). UI list update is driven by **`onEvent` → consume**, not by reading `IngestResult` on main for decorator sync today. Dual-pathing “sometimes consume event, sometimes also read result” is easy to get wrong.

### Accepted: widen the callback

**Today:**

```text
onEvent: @Sendable (StoreEvent) async -> Void
AppDelegate: { event in History.shared.consume(event) }
```

**Target:**

```text
onEvent: @Sendable (StoreEvent, [PersistentIdentifier]) async -> Void
// second arg = trimmed/deleted persistent IDs for this ingest (may be empty)

History.consume(_ event: StoreEvent, trimmedPersistentIDs: [PersistentIdentifier] = [])
```

### Why `PersistentIdentifier`

- `ItemSnapshotDTO` is already `Sendable` and carries `persistentID: PersistentIdentifier?` — **Sendable constraint proven** in-tree.  
- Decorator identity for removal is `decorator.item.persistentModelID`, not search `UUID` and not `ItemID` string form.  
- Actor has `@Model` refs in hand **before** `context.delete` — capture `persistentModelID` there.

### Defaulted parameter

```swift
func consume(_ event: StoreEvent, trimmedPersistentIDs: [PersistentIdentifier] = [])
```

- Existing tests calling `consume(.added(snapshot))` **compile unchanged**.  
- Empty list → behavior can keep calling full `syncAllToStore` (safe default) or no-op extra removals.

### Churn estimate (~5 production touch points)

| Site | Change |
|------|--------|
| `ClipboardIngestor` `onEvent` type | add `[PersistentIdentifier]` |
| Actor emit site (~`:242`) | pass captured ids |
| `commit` | return or out-param persistent IDs alongside ItemIDs |
| `AppDelegate` closure | forward both args |
| `History.consume` / `insertIncrementally` | apply trimmed set; skip or narrow `syncAllToStore` |

**No** `StoreEvent` enum churn. **No** mass test construction updates.

---

## 4. Capture set contents (correctness)

From `commit` / ingest path, the trimmed set **must** include:

| Source | Why |
|--------|-----|
| **Duplicate victim** (`dup`) | `.merged` survivor has a **new** identity path; `insertIncrementally` only drops decorators matching the **survivor** `persistentID`. Orphan dup decorator is removed today **only** by `syncAllToStore`. **Must keep this id in D4 set.** |
| **Size-trim excess** rows | Oldest unpinned beyond limit — not in UI sort order; cannot local-tail-trim `all` |

Optional: ids already absent from `all` → removal is no-op (safe).

---

## 5. Main-side algorithm (sketch)

```text
consume(event, trimmedPersistentIDs):
  switch event:
    added/merged(snapshot):
      insertIncrementally(snapshot, trimmedPersistentIDs)
    removed/cleared:
      reconcileWithStore()   // unchanged fallback

insertIncrementally(snapshot, trimmedPersistentIDs):
  ... existing guards; on failure reconcile and return ...
  binary insert decorator
  async corpus update
  if trimmedPersistentIDs nonEmpty:
    removeFromAll(persistentIDs: Set(trimmedPersistentIDs))  // O(deleted) scan or set membership
    searchActor.remove(removedDecoratorUUIDs)
  else:
    syncAllToStore()   // preserve old behavior when caller didn't pass ids (tests)
  refreshVisibleItems + UI effects
```

**Policy choice (lock in implementation PR):**

| Policy | Pros | Cons |
|--------|------|------|
| A. Always prefer trimmed set when non-empty; never full sync on happy path | Max perf | Must be correct set |
| B. Apply trimmed set **and** still syncAll | Safety belt | Loses P |
| C. Empty trimmed → full syncAll (compat) | Tests OK | — |

**Recommended:** **A + C** — non-empty trimmed replaces syncAll on happy path; empty keeps syncAll; keep syncAll/reconcile as fallback on guard failure. Add a DEBUG or test hook if we still need DS-002 force-fail on full sync path.

---

## 6. Measure-first protocol (mandatory)

D4’s headline is **performance**. Unmeasured D4 can be hollow if `fetchIdentifiers` is already cheap on the runner.

### Step M1 — baseline commit (no behavior change)

```text
feat(d4): add per-copy@n=1000 perf baseline
```

- Extend existing perf harness that exercises full `consume(.added)` (4.4a-era path).  
- Attribute or isolate cost of the sync-all slice as far as practical (at minimum: end-to-end per-copy at n=1000 with history prefilled).  
- Push; read **perf-text** (or relevant) shard.  
- Keep the test as a **regression gate** regardless of go/no-go.

### Step M2 — interpret

| Result | Action |
|--------|--------|
| Material cost (order-of-magnitude: **≫ ~100µs/copy** attributable, or clear n-scaling) | Implement D4 as in §3–5 |
| Negligible (**≪ ~20µs** or flat vs n) | **Do not sell D4 as perf.** Residual value = one fewer dual-IO site + D1 prep → only worth it if **D1 near-term** → **cascade to D0 Load ADR** (master roadmap §5 #1) |
| Flaky RSD on sub-ms measures | Follow project flake rules; don’t loop reruns; widen measure or use higher n |

Thresholds are **guidance** for human judgment on CI numbers, not hard physics.

### Step M3 — implement D4 (behavior PR)

```text
perf(d4): apply ingest trimmed persistent IDs on consume (O(deleted) sync)
```

- TDD: test that a merge/trim deletes the **dup decorator** without relying on full identifier fetch (inject trimmed ids into `consume`).  
- Preserve DS-002 semantics on any remaining full-sync path.  
- No file split in this PR.

---

## 7. Tests to add / keep

| Test | Intent |
|------|--------|
| Existing DS-002 syncAll fetch failure | Keep green on fallback path |
| **New:** merge ingest supplies dup’s persistentID in trimmed set → orphan decorator gone; `all` count correct | Locks the §4 trap |
| **New:** size-trim ids remove corresponding decorators | Trim path |
| **New / extended:** empty trimmed list still consistent (full sync or documented behavior) | Compat |
| Perf baseline | M1 gate |

Avoid depending on real `Storage.fetchIdentifiers` failure for the happy-path D4 test — pass trimmed ids explicitly.

---

## 8. Pairing with D5 / D6 (not in D4 PR)

| ID | Topic | Relation |
|----|-------|----------|
| D5 | Actor `commit` full unpinned fetch+sort | Sibling O(n); separate PR |
| D6 | `loadAfterDefaultsChange` → `reconcileWithStore` | Small; can follow D4; different cluster |
| D0/D1 | Windowed load | Cascade if M2 says D4 cheap |

---

## 9. Risks

| Risk | Mitigation |
|------|------------|
| Missing dup id in trimmed set | Explicit test §4; code review checklist |
| Stale `all` if actor delete set incomplete | Fallback reconcile on guards; optional periodic full sync **not** required now |
| Sendable / MainActor mistakes on callback | Mirror existing `onEvent` isolation pattern |
| Perf test flake | Project known RSD issues; interpret with care |

---

## 10. Done when

- [ ] M1 baseline on CI recorded in PR / audit note  
- [ ] M2 go/no-go written (even if no-go → D0)  
- [ ] If go: O(deleted) happy path + tests for dup + trim  
- [ ] Fallback paths still safe (DS-002 class)  
- [ ] No History file split in the same PR  
- [ ] `NEW-history-spine-2` marked closed in tracking notes  

---

## 11. One-line design summary

**Widen `onEvent` to pass `[PersistentIdentifier]` deletes from the actor; apply them on main in O(deleted); keep full sync/reconcile as fallback; measure before claiming the win.**
