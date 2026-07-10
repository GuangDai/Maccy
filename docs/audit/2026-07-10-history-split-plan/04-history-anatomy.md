# 04 — History Anatomy (what would split, and what must not)

**Baseline:** `Maccy/Observables/History.swift` @ HEAD · Design target from `04-module-history.md` §12 · **Inventory only**

---

## 1. Declared vs actual responsibility

**Declared (doc comment):** main-actor clipboard history model — `items`/`all`, persistence, search, pin/delete/clear, consuming ingest `StoreEvent`s.

**Actual responsibilities** (refined from design audit §2; line ranges approximate at 978-LOC HEAD):

| # | Cluster | Symbols (representative) | ~LOC band | Change frequency |
|---|---------|--------------------------|-----------|------------------|
| 1 | **List / visible state** | `items`, `all`, pinned/unpinned filters, shortcuts | state + helpers | High (every search/ingest) |
| 2 | **Defaults observers** | `init` Tasks on pasteByDefault, sortBy, pinTo, symbols, image sizes, searchBodyLimit | ~70 in init | Low |
| 3 | **Cold load** | `load`, `loadAndRecordError`, DEBUG force load fail, `limitHistorySize` | ~60 | Med |
| 4 | **Legacy write** | `add`, `findSimilarItem`, `mergeDuplicateIfNeeded`, `sessionLog`, `isModified`, `insertDecorator` | ~80–120 | Test-only / dead prod |
| 5 | **Store projection** | `consume`, `insertIncrementally`, `syncAllToStore`, `reconcileWithStore` | ~170 | **Hot path** (every copy) |
| 6 | **User mutations** | `delete`, `clear`, `clearAll`, `togglePin`, `select`, `cleanup` | ~180 | Med |
| 7 | **Search session** | stream/debounce, `performSearch`, apply, corpusEntry, generation, invalidate | ~130+ | High (keystrokes) |
| 8 | **Error scratch** | `lastPersistError`, `recordPersistenceError` | small | Low |
| 9 | **UI chrome effects** | 23× `AppState.shared` | scattered | Coupled to 5–7 |
| 10 | **Clipboard side effects** | clear/copy on clear*/select | in mutations | Med |
| 11 | **HistoryRef** | `decorators()` | 4 | Memory governor |
| 12 | **Paste stack** | other file; dead | 102 | Dead |

**Verdict (unchanged):** multiple reasons to change → god object (DS-001). **Sequence** of decomposition is what this suite freezes — not the inventory.

---

## 2. Target boundary (design audit — still the *end state*)

From [`04-module-history.md`](../2026-07-09-design-structure-audit/04-module-history.md) §12 / [`18-target-architecture.md`](../2026-07-09-design-structure-audit/18-target-architecture.md):

```text
History (facade name kept for API stability)
  ├─ HistoryListState         all, items, shortcuts
  ├─ HistoryStoreProjector    load?, consume, reconcile, syncAll
  ├─ HistorySearchSession     query, generation, actor, apply
  ├─ HistoryMutations         delete, clear, pin, select orchestration
  ├─ LegacyHistoryWriter      add (test-only until deleted)
  └─ UI effects               inversion — NOT a singleton-wrapping port
```

**This suite does not implement this graph now.** It is the long-term shape. Near-term only **D4** mutates cluster 5’s algorithm; extraction waits for forcing-gate / D1.

---

## 3. State ownership (must stay coherent)

| State | Observed? | Lifetime | Writers | Readers |
|-------|-----------|----------|---------|---------|
| `items` | **Yes** (`@Observable`) | Session | search apply, load, mutations | Views, intents |
| `searchQuery` | **Yes** | Session | UI / select clear | search consumer |
| `pasteStack` | Yes | Short | dead path | dead UI |
| `lastPersistError` | Yes | Until next | record* | tests / future UI |
| `all` | **No** (`@ObservationIgnored`) | Session | load, consume, add, delete, clear | search, mutations, HistoryRef |
| `searchGeneration` / `searchTask` | No | Session | search + destructive ops | apply guard |
| `sessionLog` | No | Session | **legacy add only** | isModified |
| `persistence` | No | Init | — | IO |

### Observation binding constraint

Extracting **observed** fields into a child type breaks SwiftUI unless:

- the child is `@Observable`, **and**  
- views observe through a stable path on the facade.

**Implication:** first real type extraction should prefer **`all` + IO** (`StoreProjector`) — `all` is already `@ObservationIgnored` — **when D1 needs it**. Do **not** start by extracting `searchQuery` / `items`.

---

## 4. Dependency graph (outbound)

```text
History
  → HistoryPersistence (partial; dual channel remains)
  → Storage.shared.context (5 direct sites)
  → SearchActor + legacy Search
  → Sorter, BinaryInsertion
  → Defaults
  → AppState.shared (×23)
  → Clipboard.shared (select/clear paths)
  → Notifier / Sauce / NSApp (shortcuts, events)
```

Inbound: AppDelegate onEvent, AppState/Views/Intents, MemoryGovernor via HistoryRef, tests.

---

## 5. Cluster dependency rules (for a future split)

| From → To | Allowed? |
|-----------|----------|
| Mutations → List state | Yes |
| Projector → List state (`all`) | Yes |
| Search → List state | Yes (read `all`, write `items`) |
| List state → AppState | **No** (effects only at orchestrator edge) |
| Search → Storage | **No** |
| Legacy → Projector | Avoid; isolate until deleted |
| Projector → AppState | Today yes (select/resize); long-term effect intents |

---

## 6. What already left the file

| Piece | Location | Notes |
|-------|----------|-------|
| Persistence protocol + SwiftData impl | `HistoryPersistence.swift` | Complete the port later with B2/D1 — not standalone |
| Paste stack | `History+PasteStack.swift` | Dead; E4 delete candidate |

---

## 7. Hot path deep dive (cluster 5) — why D4 lives here

```text
StoreEvent.added/.merged(snapshot)
  → insertIncrementally
       guard persistentID
       remove decorator with same persistentID (merged re-insert)
       model(for:) + title gate else reconcileWithStore
       binary insert into all
       Task { searchActor insert/remove }
       syncAllToStore()          ← O(rows) fetchIdentifiers + scan all
       refreshVisibleItems()
       AppState select/resize
```

**`syncAllToStore` purpose (comment):** ingest trim order is oldest-unpinned by `lastCopiedAt`, **not** UI sort order — local tail trim is wrong; sync by membership in store id set.

**D4 insight:** actor **already knows** which models it deleted (dup + size trim). Main should apply that set instead of re-deriving via full identifier fetch. See `06`.

**Correctness trap (verified):** on `.merged`, the **deleted dup’s** decorator is **not** removed by the “same persistentID” branch (that id is the *survivor*). Today only `syncAllToStore` drops the orphan decorator. D4’s trimmed set **must include the dup’s `persistentModelID`**.

---

## 8. Search cluster notes (do not split first)

- Dual engine: empty query → legacy `Search`; non-empty → `SearchActor` (C3 later).  
- Generation guard on apply.  
- `invalidateInFlightSearch` co-located with search helpers — **B5 / Wave A fix traffic** lives here.  
- **Forcing-gate rule:** never move Search cluster first; rebase cost against the most active correctness patch surface.

---

## 9. Legacy cluster notes

- `MainActorIngestorAdapter` docstring still claims legacy path “until actor is wired” — **doc rot** (actor is production).  
- ~45 test call sites still use `add`.  
- **When split gate fires:** B3 migrate tests → B4 delete legacy **before** multi-file extension split if headroom is the issue (~80 LOC permanent delete > reshuffling).

---

## 10. Mapping clusters → future files (only after gate)

| Order when forced | Suggested file | Contents |
|-------------------|----------------|----------|
| 0 (prefer delete) | — | B3/B4 remove legacy |
| 1 | `History+Reconcile.swift` | consume, insertIncrementally, syncAll, reconcile (**post-D4**) |
| 2 | `History+Mutations.swift` | delete/clear/pin/select + cleanup |
| 3 | `History+SearchSession.swift` | search methods only; **state stays on class** |
| 4 | `History+LegacyWrite.swift` | only if B4 not yet done |
| later | real types | StoreProjector at D1; others when consumers exist |

Same-file `extension` without new files is **not** recommended as a goal — it doesn’t help `file_length` and doesn’t reduce coupling.

---

## 11. One-line anatomy summary

**History is one observable facade with a hot store-projection spine, a search session, user mutations, and a dead legacy writer; only the projection spine should change next (D4), and only `all`+IO is a credible first real type when D1 arrives.**
