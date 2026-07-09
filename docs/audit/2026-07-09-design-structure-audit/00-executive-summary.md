# 00 — Executive Summary

**Baseline:** HEAD `6cd37c8` · **Scope:** design structure only · **Language:** English  
**Primary deep evidence:** [`02-end-to-end-data-flows.md`](02-end-to-end-data-flows.md), [`17-findings-catalog.md`](17-findings-catalog.md)

---

## 1. One-sentence judgment

Maccy has a **real** concurrency split (background ingest / search / image actors + Sendable DTOs), but the **system is mid-migration**: a production actor write path coexists with a **test-live legacy `History.add` path**, cold load still **faults the entire table on the main context**, and **`History` (989 lines) is the single largest cohesion failure**, wired to `AppState.shared` in **23 call sites** inside one file.

The dominant design debt is not “no architecture.” It is **multiple sources of truth for the same facts** (store vs `all` vs search corpus vs SignatureIndex) without a single event model covering UI mutations.

---

## 2. Scale (evidence)

| Artifact | Size (LOC / count) |
|----------|-------------------|
| `History.swift` | **989** |
| `HistoryItemDecorator.swift` | 554 |
| `ClipboardIngestor.swift` | 500 |
| `Clipboard.swift` | 416 |
| `AppDelegate.swift` | 390 |
| Production Swift under `Maccy/` | **120 files** |
| `*.shared` hits (four main singletons) | **171** across 26 files |

---

## 3. What is solid (do not casually rewrite)

| Area | Why |
|------|-----|
| `@Model` never crosses actors; DTOs do | Explicit in ingest/search design |
| Single-transaction ingest commit | `commit(_:deleting:limit:)` one `transaction` + one `save` |
| Dedup: index candidates + `supersedes` + `dataLikelyEqual` still `==` after hash | Collision-safe |
| Search generation + title equality guard | Stale apply discarded |
| ImageIO downsample + cancel checkpoints | Off-main decode |
| UTF-8 prefix validation in C++ | Correctness-critical |
| `HistoryPersistence` protocol injection point | Testability seed (implementation still hard-codes `Storage.shared`) |

---

## 4. System health scores

| Dimension | Score | Evidence summary |
|-----------|-------|------------------|
| Directory clarity | Medium | Good packages (`Ingest/`, `ImageProcessing/`); root + `Observables/` overloaded |
| Domain model | Weak–medium | `@Model` + AppKit + Defaults + Storage queries |
| Layering | Medium | Actor islands good; singleton bus + History→AppState breaks layers |
| Live ingest pipeline | Medium–strong | Clear steps; forced `MainActor.run` for filter/title |
| Load pipeline | Weak | Unbounded fetch; `VisibleWindowLoader` unwired |
| Search pipeline | Medium–strong | Actor corpus solid; dual engine for empty query |
| Cohesion | History **very low**; Ingest **high** | See `16` |
| Testability | Medium–strong | Support doubles; production still singleton-heavy; tests train on `add` |
| Evolvability | Medium | DTOs help; dual paths and god object tax every change |

---

## 5. Top problems (priority)

| Rank | ID | Problem | Why first |
|------|-----|---------|-----------|
| 1 | **DS-002** | `syncAllToStore` treats fetch failure as empty store | Possible **UI wipe** of all decorators while DB intact |
| 2 | **DS-001** | `History` god object | Blocks safe change of almost every feature |
| 3 | **DS-003** | Live ingest vs legacy `add` | Semantic split; cannot delete “dead” code without test rewrite |
| 4 | **DS-007** | 23× `AppState.shared` from `History` | Projection inseparable from chrome |
| 5 | **DS-004** | Full-table `load` + unwired window loader | Memory + main-thread cost; dual read API |
| 6 | **DS-005** | Three IDs + two signatures | Cognitive + sync bugs on merge |
| 7 | **DS-009** | UI delete does not update actor `SignatureIndex` | Stale candidates until process restart / rebuild |
| 8 | **DS-008** | Dual filter rules + dead Clipboard helpers | Drift + noise |
| 9 | **DS-010** | Dual search engines | Behavior drift risk |
| 10 | **DS-006** | Global `shared` bus | Hidden dependencies everywhere |

Full catalog: [`17-findings-catalog.md`](17-findings-catalog.md).

---

## 6. HEAD re-checks vs older audit docs

| Older claim | HEAD `6cd37c8` |
|-------------|----------------|
| Fingerprint lazy backfill “missing” | **Partial:** `backfillMissingFingerprints` on **dedup candidates only** |
| `dataFromFileIfAllowed` OOM via `fileSize ?? 0` | **Fixed pattern:** failure returns `nil` |
| `DecodedImageCache` dead code | **Type removed**; comments say intentional |
| `item(before:)` trap on first element | **Guarded** in HEAD (`currentIndex > startIndex`) |
| Production path is actor ingest | **Confirmed** (`AppDelegate` wires `BackgroundClipboardIngestor`) |

---

## 7. Multi-writer / multi-projection problem (core systems issue)

```text
                    ┌── SignatureIndex (actor memory)
Store (SQLite) ─────┼── mainContext row cache
                    ├── History.all / items (decorators)
                    └── SearchActor corpus

Writers:
  - BackgroundClipboardIngestor (insert/merge/trim)
  - History persistence (delete/clear/pin/save)
  - Legacy History.add (tests)
```

**There is no single domain event** that updates all projections for UI deletes. Ingest emits `StoreEvent` for adds/merges only; deletes from UI patch arrays + search corpus but **not** SignatureIndex (DS-009). `syncAllToStore` only reconciles `all` toward store IDs after ingest trim.

---

## 8. What not to touch without extreme care

1. `ClipboardDataProcessor.dataLikelyEqual` post-hash full compare  
2. C++ UTF-8 validation  
3. Ingest single-transaction ordering (delete dup → trim → insert → save)  
4. Search generation + title equality apply guards  
5. `mainContext.reset()` as a memory fix (breaks incremental identity; see memory suite)  
6. One PR that moves directories + changes dedup + changes load  

---

## 9. Over-design traps

- Full DDD package tree in one migration  
- Generic event bus replacing typed `StoreEvent`  
- Search index without measured need  
- Repository pyramid for one SQLite aggregate  

---

## 10. Next steps

Ordered engineering playbook: [`19-master-playbook.md`](19-master-playbook.md).  
If you only verify one thing next: **DS-002** with fault-injection on `fetchIdentifiers`.
