# 11 — Module: Storage / Persistence

**Files:** `Storage.swift` (175), `Persistence/Storage+Background.swift`  
**Baseline:** HEAD `6cd37c8` · Flow B

---

## 1. Storage

| Responsibility | Detail |
|----------------|--------|
| ModelContainer owner | `HistoryItem` schema |
| mainContext | `container.mainContext` |
| Corruption recovery | quarantine store files + empty recreate / in-memory fallback + alert |
| size string | on-disk byte count for Settings |

`@MainActor class` + `shared`. Testing: `enable-testing` → in-memory.

Recovery yields **empty history** — product decision, user-visible.

---

## 2. Two-context model

```text
Storage.shared.container
  ├─ mainContext          // History UI read/delete/pin
  └─ actor ModelContext   // BackgroundClipboardIngestor
```

Comments: no `automaticallyMergesChangesFromParent`; visibility via shared store commits.

`newBackgroundContext()` exists; ingestor uses `@ModelActor` executor context instead.

---

## 3. VisibleWindowLoader (DS-004)

| Intent | Bounded fetch + snapshot split visible/tail |
| Status | **Not called from History.load** |
| Tests | StorageBackgroundContextTests |
| Comment in source | “not yet wired into the live read path” |

### Why wiring is hard

- Today load produces full `[HistoryItemDecorator]` bound to mainContext entities  
- Search corpus expects full `all`  
- Pin partitioning + sort interaction  
- Windowing alone does **not** free mainContext blob cache (memory suite)  

**Decision required before code:** wire vs delete.

---

## 4. HistoryPersistence

Defined in History.swift; implementation hard-codes Storage.shared. Incomplete port (DS-022).

---

## 5. Findings

DS-004, DS-022, DS-025 (predicate delete), recovery policy documentation.

---

## 6. Target

```text
Storage: container lifecycle + recovery only
HistoryRepository: main CRUD port (complete)
Ingest uses actor context only
ReadModel: formalize or remove VisibleWindowLoader
```

**Confidence:** High.
