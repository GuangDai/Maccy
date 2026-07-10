# 01 — Baseline Inventory (measured at HEAD)

**Baseline:** HEAD `bfcf671` · Sources: `Maccy/Observables/History.swift`, `HistoryPersistence.swift`, `History+PasteStack.swift`, ingest DTOs, git history · **No product changes**

---

## 1. File sizes

| Path | LOC (wc -l) | Role |
|------|-------------|------|
| `Maccy/Observables/History.swift` | **978** | God object (primary subject) |
| `Maccy/Observables/HistoryPersistence.swift` | 84 | Port + SwiftData adapter (extracted `6b88f48`) |
| `Maccy/Observables/History+PasteStack.swift` | 102 | Extension; **dead feature** under `multiSelectionEnabled = false` |
| `Maccy/Observables/HistoryItemDecorator.swift` | 554 | Sister large type (not in scope of split order) |
| `Maccy/Ingest/ClipboardIngestor.swift` | 553 | Live ingest actor |

### Type body (brace span, approximate)

| Declaration | Span (start–end lines) | ~Lines |
|-------------|------------------------|--------|
| `class History` | L16–L973 | **~958** |
| `extension History: HistoryRef` | L975–L978 | 4 |

Observation: almost the entire file is **one class body**. The only extension is the tiny `HistoryRef` conformance.

---

## 2. `History` growth under custom lint

| Commit | Date | `History.swift` LOC | Event |
|--------|------|---------------------|--------|
| `a8365fa` | 2026-06-24 | **796** | Raise length rules to 1000; drop disables |
| `a1411c8` | ~06-25 | 797 | memory / incremental consume era |
| `4fa4946` | 2026-06-28 | 933 | SearchActor land |
| `d933dff` | 2026-07-04 | **1000** | At file wall |
| `040fbfa` | 2026-07-04 | **1060** | Corpus on actor; **file_length CI fail** |
| `b4667d8` | 2026-07-04 | 964 | Extract paste-stack **for file_length** |
| `6b88f48` | 2026-07-09 | 937 | Extract `HistoryPersistence` |
| Wave A patches | 2026-07-09/10 | → **978** | load/pin/select invalidate + error surfaces |
| HEAD `bfcf671` | 2026-07-10 | **978** | B1 demoted in docs only |

**Headroom today:** 1000 − 978 = **22 lines** of `file_length` before hard error (with project thresholds; CI `--strict`).

---

## 3. Already-landed extractions (and why)

| Extract | Commit | Motivation | Hollow? |
|---------|--------|------------|---------|
| `History+PasteStack.swift` | `b4667d8` | Clear `file_length` after 1060 | **Mostly lint-driven**; boundary is coherent *if* multi-select were live, but feature is dead (E4) |
| `HistoryPersistence.swift` | `6b88f48` | file_length + start of store port | **Partial value** — write path through port; **read/reconcile still dual** (DS-022) |
| UIEffectPort | tried 2026-07-10 | DS-007 | **Reverted** — hollow (`bfcf671`) |

---

## 4. Dual IO channel (DS-022) — five direct sites

All in `History.swift` (grep `Storage.shared`):

| # | Approx line | Call | Path / notes |
|---|-------------|------|----------------|
| 1 | 210 | `context.fetch(FetchDescriptor<HistoryItem>())` | `load()` — **could** use existing `persistence.fetchAll()` |
| 2 | 337 | `context.model(for: persistentID) as? HistoryItem` | `insertIncrementally` — not on port today |
| 3 | 403 | `context.fetchIdentifiers(FetchDescriptor<HistoryItem>())` | `syncAllToStore` — not on port today |
| 4 | 434 | `context.fetch(FetchDescriptor<HistoryItem>())` | `reconcileWithStore` — **could** use `fetchAll()` |
| 5 | 497 | `context.delete(existingHistoryItem)` | `mergeDuplicateIfNeeded` (legacy `add` path) |

### Port surface today (`HistoryPersistence`)

```text
insert / delete / deleteUnpinned / deleteAll / save
fetchAll / countHistoryItems / countHistoryItemContents
```

**Used from History for mutations & legacy findSimilar**, not for load/reconcile/syncAll/`model(for:)`.

---

## 5. `AppState.shared` coupling (DS-007)

**Count: 23** sites in `History.swift` (not 22 — prior notes occasionally under-counted).

Categories:

| Category | Examples |
|----------|----------|
| Popup chrome | `popup.needsResize`, `popup.close` |
| Navigator selection | `navigator.select`, `highlightFirst`, `scrollTarget` |
| Multi-select guard | `navigator.isMultiSelectInProgress` (always false in prod; dead branch) |

**B1 lesson:** wrapping these in a protocol whose only production adapter calls `AppState.shared` **relocates** coupling. Real fix = **inversion** (History emits effect intents; UI owns AppState). Deferred with projection work — not a near-term PR.

---

## 6. Production vs test entrypoints

| Entrypoint | Production | Tests |
|------------|------------|-------|
| `consume(_:)` | **Yes** — `AppDelegate` `onEvent` | `HistoryConsumeTests`, image perf |
| `load()` / `loadAndRecordError` | Yes (popup / prewarm / defaults) | yes |
| `add` / `findSimilarItem` / `sessionLog` | **No live wiring** | **Heavy** (~45 `history.add` sites / 5 files) |
| `MainActorIngestorAdapter.ingest` | **Dead** (0 instantiation as live ingestor) | `historyItem(from:)` still used in tests |
| pin / delete / clear / select | Yes | yes |

Live path:

```text
Clipboard change → BackgroundClipboardIngestor.ingest
  → single transaction + deletedItemIDs (internal)
  → onEvent(StoreEvent) → History.consume → insertIncrementally / reconcile
  → syncAllToStore (full fetchIdentifiers today)
```

---

## 7. Search generation discipline (post–Wave A)

`invalidateInFlightSearch()` call sites at HEAD include: `load`, `clear`, `clearAll`, `delete`, `select`, `togglePin`, empty-query branch in `performSearch`, plus the helper definition.

Wave A closed the bug-class *symptomatically*. **B5** (single chokepoint: any list mutation cancels in-flight search) remains a structural follow-up — **does not require a file split**.

---

## 8. Related Wave A / extract commits (reference)

| Commit | Note |
|--------|------|
| `2d3ea6c` | DS-002: syncAll abort on fetch failure |
| `0355dbe` | DS-023: load failures recorded |
| `122e661` | DS-013 + spine-3/4: pin/load/select invalidate |
| `7fb08bd` / `150a8a4` | ingest persistence failure surface |
| `6b88f48` | HistoryPersistence extract |
| `bfcf671` | demote B1 UIEffectPort in roadmap |

---

## 9. Sister large types (context only)

If stock `type_body_length` error **350** were restored without plan, these would also be in the blast radius (approx spans ≥350):

| Type | ~span | File |
|------|-------|------|
| `History` | 958 | History.swift |
| `HistoryItemDecorator` | 542 | HistoryItemDecorator.swift |
| `BackgroundClipboardIngestor` | 472 | ClipboardIngestor.swift |
| Large test classes | 440–550 | several under `MaccyTests/` |
| `AppDelegate` | 382 | AppDelegate.swift |
| `NavigationManager` | 357 | NavigationManager.swift |

**Implication:** lint restore is a **repo-wide process decision**, not a free History-only fix. See `02`.
