# 04 — Module: History (God Object)

**File:** `Maccy/Observables/History.swift` (**989 LOC**)  
**Baseline:** HEAD `6cd37c8`  
**Related:** Flow A.14–F in `02`, findings DS-001,002,003,007,012–014,021–023

---

## 1. Declared responsibility

Doc comment (~93–95): main-actor clipboard history model — `items`/`all`, persistence, search, pin/delete/clear, consuming ingest `StoreEvent`s.

---

## 2. Actual responsibilities (inventory)

| # | Responsibility | Symbols / evidence |
|---|----------------|-------------------|
| 1 | List projection state | `all`, `items`, `pinnedItems`, `unpinnedItems` |
| 2 | Persistence port | `HistoryPersistence`, `SwiftDataHistoryPersistence` |
| 3 | **Also** direct Storage access | `load`, `reconcileWithStore`, `syncAllToStore`, `mergeDuplicateIfNeeded` use `Storage.shared.context` |
| 4 | Cold load | `load` 269–284 |
| 5 | Incremental + full reconcile | `consume`, `insertIncrementally`, `reconcileWithStore`, `syncAllToStore` |
| 6 | **Legacy write path** | `add`, `findSimilarItem`, `mergeDuplicateIfNeeded`, `sessionLog`, `isModified` |
| 7 | Size limiting | `limitHistorySize` → per-item `delete` |
| 8 | Search session | query stream, debounce, generation, `SearchActor`, legacy `Search`, apply |
| 9 | User mutations | `delete`, `clear`, `clearAll`, `togglePin`, `select` |
| 10 | Shortcut assignment | `updateShortcuts`, `updateUnpinnedShortcuts` |
| 11 | Defaults reactions | Tasks on pasteByDefault, sortBy, pinTo, showSpecialSymbols, image sizes, searchBodyLimit |
| 12 | UI chrome side effects | **23** `AppState.shared` sites |
| 13 | Clipboard side effects | clear on clear*; copy on select |
| 14 | Error scratch | `lastPersistError` |
| 15 | Memory protocol | `HistoryRef.decorators()` |

**Verdict:** Far beyond a view-model. **DS-001.**

---

## 3. Types embedded in the same file

1. `HistoryPersistence` protocol  
2. `SwiftDataHistoryPersistence` — **hard-codes** `Storage.shared` despite DI  
3. `History` class  
4. `History: HistoryRef` extension  

---

## 4. State ownership

| State | Lifetime | Writers | Readers |
|-------|----------|---------|---------|
| `all` / `items` | Process session | load, consume, add, delete, clear, search apply | Views, Navigator, AppState |
| `searchGeneration` / `searchTask` | Session | search + destructive ops | apply guard |
| SearchActor corpus | Best-effort mirror of `all` | Tasks from History ops | search |
| `sessionLog` | Session | **legacy add only** | `isModified` |
| `lastPersistError` | Until next error | `recordPersistenceError` | tests / potential UI |
| `pasteStack` | Short | PasteStack extension | UI |

---

## 5. Dependency graph

**Outbound:**

- `Storage.shared` (direct)  
- `persistence` (injected default still shared storage)  
- `SearchActor`, `Search`, `Sorter`  
- `Defaults`  
- `AppState.shared` (popup, navigator) — **23 sites**  
- `Clipboard.shared`  
- `Notifier`, Sauce/NSApp  

**Inbound:**

- AppDelegate `onEvent`  
- AppState / Views / Intents  
- Clipboard paste-stack interrupt  
- MemoryGovernor via `HistoryRef`  
- Tests  

### Unsound dual IO channel (DS-022)

| Path | Uses |
|------|------|
| delete / clear / insert in add | `persistence.*` |
| load / reconcile / syncAll / merge delete | `Storage.shared.context` directly |

Injecting a fake `HistoryPersistence` **does not** intercept load/reconcile.

---

## 6. Production vs test entrypoints

| Entrypoint | Production | Tests |
|------------|------------|-------|
| `consume` | **Yes** (live ingest) | HistoryConsumeTests, image perf via consume |
| `load` | Yes (popup/prewarm) | some |
| `add` | **No** (AppDelegate) | **Yes** heavily |
| `select` / pin / delete | Yes | yes |

---

## 7. Critical path deep dive: `syncAllToStore` (DS-002)

```text
insertIncrementally → syncAllToStore after insert
```

Purpose (comment): ingest trim order is `lastCopiedAt` oldest-unpinned, **not** UI sort order, so local trim is wrong; sync by id set.

**Bug-shaped code:**

```text
storeIDs = Set(try? fetchIdentifiers ?? [])  // failure → []
for decorator in all:
  if not in storeIDs: cleanup + remove
```

| Scenario | Result |
|----------|--------|
| Fetch succeeds, N ids | Remove only trimmed |
| Fetch succeeds, 0 ids (empty DB) | Clear all decorators — correct |
| Fetch **throws** | Clear all decorators — **incorrect** |

**Recommendation:** never default failure to empty set.

---

## 8. Critical path: `insertIncrementally` guards

```text
nil persistentID → reconcile
model(for:) cast fail OR title != snapshot.title → reconcile
else binary insert + async corpus + syncAll + UI effects
```

Title gate (`DS-021`): empty shell title vs non-empty snapshot forces full reconcile (safe, expensive).

Binary insertion uses same order as `Sorter.areInIncreasingOrder` (good).

---

## 9. Search orchestration issues

| Issue | Detail |
|-------|--------|
| Dual engine | empty → `Search`; non-empty → `SearchActor` |
| O(n) resolve | `all.first { id }` |
| Pin | no generation invalidation |
| Corpus Tasks | unstructured, can lag |

---

## 10. Legacy `add` path (keep until tests migrate)

```text
insert → mergeDuplicateIfNeeded(findSimilar full fetch) → limit → sessionLog → insertDecorator → refresh
```

`findSimilarItem`: `persistence.fetchAll()` then linear `supersedes` — O(n) **per add**.

---

## 11. Cohesion assessment

| Criterion | Result |
|-----------|--------|
| Single reason to change? | **No** — dozens |
| Methods share state? | Partially (`all`/`items`) but many independent stages |
| Split axes | By change reason: projection / search / mutations / legacy / chrome |

**Do not split by arbitrary line count alone** — split by the table in §2.

---

## 12. Target boundary (recommended)

```text
HistoryFacade (keep name History for API stability)
  ├─ HistoryListState        all, items, shortcuts
  ├─ HistoryStoreProjector   load?, consume, reconcile, syncAll
  ├─ HistorySearchSession    query, generation, actor, apply
  ├─ HistoryMutations        delete, clear, pin, select orchestration
  ├─ LegacyHistoryWriter     add (test-only)
  └─ UIEffectPort            resize, close, navigate (no AppState import)
```

Dependency: Mutations/Projector → ListState; Search → ListState; effects called by orchestrators, ListState never imports AppState.

---

## 13. Testability

| Good | Bad |
|------|-----|
| `init(persistence:…)` | Default impl uses Storage.shared |
| `waitForInFlightSearch` | AppState.shared side effects |
| | load bypasses persistence port |

---

## 14. Verification checklist for this module

- [ ] Fault-inject syncAll fetch failure  
- [ ] `rg AppState.shared History.swift` → should fall after UIEffectPort  
- [ ] `rg "func add" / history.add` production zero  
- [ ] File/type split with behavior-freeze CI  
- [ ] Search id map O(1)  

---

## 15. Confidence

| Claim | Confidence |
|-------|------------|
| God object | High |
| DS-002 static path | High |
| Dual IO channel | High |
| Title gate over-reconcile frequency | Medium |
