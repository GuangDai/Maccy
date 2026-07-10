# 05 — DS-022 Close: Why Standalone Is Hollow-as-B1

**Finding id:** DS-022 (design audit) · **Verdict:** mechanism **real**; **standalone fix hollow** · **Baseline:** HEAD `bfcf671`

---

## 1. Mechanism (confirmed)

Two IO channels into SwiftData from `History`:

| Channel | Used by |
|---------|---------|
| `HistoryPersistence` / `SwiftDataHistoryPersistence` | insert, delete*, save, fetchAll (legacy findSimilar), counts |
| `Storage.shared.context` **direct** | load fetch, `model(for:)`, `fetchIdentifiers`, reconcile fetch, merge delete |

Injecting a fake `HistoryPersistence` **does not** intercept load / reconcile / syncAll / incremental model resolve.

Evidence lines: `01` §4.

---

## 2. What a standalone “close DS-022” PR would do

1. Add port methods, e.g. `fetchHistoryItemIdentifiers()`, `historyItem(for: PersistentIdentifier)`.  
2. Point the five sites at `persistence`.  
3. Keep `SwiftDataHistoryPersistence` as the only production impl — each method still calls `Storage.shared.context`.  
4. Optionally delete DEBUG force-failure flags in favor of a throwing fake.

On paper this “completes the port.” Under the hollow test it fails.

---

## 3. Hollow-test application

### C — Correctness?

**No new correctness.**

| Site | Error handling today |
|------|----------------------|
| `load()` | throws → `loadAndRecordError` |
| `syncAllToStore` | catch → `recordPersistenceError`; **does not wipe** (DS-002 fixed) |
| `reconcileWithStore` | catch → `recordPersistenceError` |
| `model(for:)` | non-throwing miss → full reconcile fallback |
| merge delete | legacy path |

Routing through a port does not fix a swallow, a wipe, or a dual-writer race. Wave A already closed the silent-failure cluster on these paths.

### P — Measured performance?

**No.** Wrappers delegate to the same SwiftData calls. D4 is the perf change; DS-022-close is not.

### T — Test unblocked *today*?

**Mostly no — redundant for the tested failure paths.**

| Path | How tested today |
|------|------------------|
| `syncAllToStore` fetch failure | `setSyncAllFetchFailureForTesting` + `HistoryConsumeTests` (DS-002) |
| `load` failure | `setLoadFailureForTesting` |
| `FailingHistoryPersistence` | throws on **insert** / **deleteUnpinned** only (`IngestErrorPropagationTests`); `fetchAll` returns empty |

A pure port-route PR does not unlock a failing test that cannot be written now. The DEBUG seams **already** force the branches without intercepting Storage.

**Hypothetical T:** “fake empty store without Storage” for load content tests — not demanded by an open bug; can wait for D1 windowed path where a fake **earns** its keep.

### G — Hard gate?

**No hard gate today.**  
D1 / windowed load would be a real gate: then a port (or projector) that can return partial windows is **G**. That is **D1**, not a standalone DS-022 PR.

---

## 4. B1 shape comparison

```text
B1 (reverted):
  History → UIEffectPort → AppStateUIEffectPort → AppState.shared

DS-022 standalone:
  History → HistoryPersistence → SwiftDataHistoryPersistence → Storage.shared.context
```

| Dimension | B1 | DS-022 standalone |
|-----------|----|-------------------|
| Indirection | +1 hop | +1 hop (for sites not already on port) |
| Singleton still in adapter | Yes | Yes |
| Runtime change | No | No |
| Existing partial port | No | Yes (writes already) |
| Less egregious? | — | Slightly (port already exists) |
| More *valuable*? | — | **No** until a second impl or D1 |

“Less egregious than B1” ≠ “worth a PR now.”

---

## 5. When DS-022-close **stops** being hollow

| Context | Why value appears |
|---------|-------------------|
| **D1 windowed load** | Fake / alt impl must return windows; intercept is load-bearing for tests and eventually for non-full-table production |
| **B2 extension split of Reconcile** *when forced* | Relocating IO **with** the cluster move can be one structure PR *if* the PR’s G is “clear forcing-gate / prepare D1” — still prefer not to expand port “for completeness” alone |
| **Second persistence backend** | None planned — do not invent |

**Rule:** fold DS-022 completion into **D1** or a **forced B2**, never ship as Wave-B “quick win.”

---

## 6. Interaction with D4

D4 **removes or shrinks** the hot-path need for `fetchIdentifiers` by applying actor-supplied deleted persistent IDs.

| Order | Result |
|-------|--------|
| D4 then later port | Hot path may no longer call `fetchIdentifiers`; port grows only what remains |
| Port then D4 | Wasted API surface for a call D4 deletes |
| Port *instead of* D4 | Hollow + misses perf |

**Sequence:** D4 first; port completion later with D1/B2.

---

## 7. What *not* to build while “closing” DS-022

- Generic `Repository<HistoryItem>`  
- Protocol inheritance pyramid  
- Changing save/processPendingChanges semantics “while here”  
- Merging behavior fixes (trim, title gate) into the same PR  

---

## 8. Doc / roadmap cross-links

| Source | Prior stance | This suite |
|--------|--------------|------------|
| Master roadmap B2 | “routes all store IO through one port” as part of file split | Keep as **part of forced B2/D1**, not near-term solo |
| First synthesis (pre-grill) | DS-022 standalone = concrete | **Superseded** by grilling + this `05` |
| Grilling `00-decision.md` | Hollow-as-B1 standalone | **Affirmed** |

---

## 9. One-line verdict

**DS-022 is a real dual channel; closing it alone is B1-shaped ceremony — schedule it only with D1 or a forced B2, after D4.**
