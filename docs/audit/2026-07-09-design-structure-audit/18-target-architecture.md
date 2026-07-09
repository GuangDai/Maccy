# 18 — Target Architecture (Principles)

**Baseline:** HEAD `6cd37c8`  
**Execution order:** see [`19-master-playbook.md`](19-master-playbook.md) — this file is the **shape**, not the schedule.

---

## 1. Keep

- Two-domain isolation + Sendable DTOs + `StoreEvent`  
- BackgroundClipboardIngestor single transaction + SignatureIndex candidates  
- SearchActor generation + title equality  
- ImageProcessor ImageIO downsample + cancel  
- Engine / ClipboardDataProcessor correctness contracts  
- HistoryPersistence **direction** (complete the port)  
- Test Support doubles  
- TextLimits single source  

---

## 2. Split

| Current | Into |
|---------|------|
| History | ListState / StoreProjector / SearchSession / Mutations / LegacyWriter |
| AppDelegate | CompositionRoot + Delegate + DebugHooks |
| Clipboard | Monitor / Writer / PasteService |

---

## 3. Merge

- Search match core + Actor → MatchEngine  
- Clipboard rule constants ⊂ IngestFilter / shared constants  
- Signature naming unified in glossary (two layers remain)  

---

## 4. Remove / isolate

- Production `History.add` family (after test migration)  
- Clipboard dead helpers  
- MainActorIngestorAdapter from production target  
- IngestPlan or real use  
- VisibleWindowLoader: **wire or delete** (binary decision)  

---

## 5. Add (sparingly)

- `UIEffectPort` / `StoreEventSink`  
- Intent `HistoryCommandService`  
- Engine accepts ContentDTO  
- Optional decorator id dictionary  
- Delete → index unregister (or rebuild)  

---

## 6. Do not add

- Generic EventBus  
- Full DDD package tree in one move  
- `mainContext.reset()` memory “fix”  
- Search index without measurement  
- Behavior + directory move in one PR  

---

## 7. Target dependency direction

```text
Views / Intents / Settings
        ↓  ports only
Application services
        ↓
Domain pure (Engine, Filter, MatchEngine, Sorter)
        ↑ adapters
Infrastructure (SwiftData, Pasteboard, ImageIO, C++, Notifier)
```

---

## 8. Multi-projection end state

```text
DomainEvent { added | merged | removed | cleared | reordered }
   → List projector
   → Search corpus projector
   → SignatureIndex projector
   → (optional) thumb prewarm
```

UI deletes and ingest trims both produce `removed` (or equivalent).

---

## 9. Compliance

Recommendations only. No product code changed by this document.
