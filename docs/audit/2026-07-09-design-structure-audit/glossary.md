# Glossary — Domain Terms, Identifiers, Signatures

Baseline HEAD: `6cd37c8`.

---

## 1. Domain concepts

| Term | Meaning | Primary symbols |
|------|---------|-----------------|
| History item | One clipboard history record (metadata + many pasteboard-type payloads) | `HistoryItem` |
| Content entry | One UTI + optional `Data` blob belonging to an item | `HistoryItemContent`, `ContentDTO` |
| Pin | Optional single-character hotkey binding persisted on the item | `HistoryItem.pin` |
| Supersedes | Containment: existing item’s non-transient contents cover the new item’s signature → treat as duplicate/merge | `HistoryItem.supersedes`, `HistoryItemEngine` |
| Merge | On duplicate: preserve firstCopiedAt, pin, accumulate `numberOfCopies`, usually keep existing contents, bump `lastCopiedAt` | `mergeFields`, `mergeDuplicateIfNeeded` |
| Title | Single-line list label (may be empty for images) | `HistoryItem.title`, `generateTitle()` |
| searchText | Full searchable body stored at ingest | `HistoryItem.searchText` |
| Fingerprint | xxh3 hash for large blobs (≥ 16 KiB); `nil` for small | `HistoryItemContent.fingerprint`, `ClipboardDataProcessor` |
| StoreEvent | Sendable change notice from ingest actor to main-thread projector | `StoreEvent` |
| Decorator | Main-actor list-row projection (not persisted) | `HistoryItemDecorator` |
| Corpus | Search actor’s owned searchable projection of the list | `SearchCorpusItem` in `SearchActor` |
| Live ingest | Production path: pasteboard → actor → `StoreEvent` → `History.consume` | — |
| Legacy add | Main-thread `History.add` + `findSimilarItem` (production dead; tests live) | — |

---

## 2. Stored and presentation identities (do not conflate)

| Name | Type | Stable across? | How created | Used for |
|------|------|----------------|-------------|----------|
| **PersistentIdentifier** | SwiftData fetch handle | App relaunches (same store row) | Assigned on insert/save | `model(for:)`, reconciliation, `sessionLog` values |
| **StoredItemID** | `PersistentIdentifier.ID` | Stable within its containing store | Exposed directly by SwiftData | `SignatureIndex` keys, `StoreEvent.removed`, `snapshot.id` |
| **Decorator id** | `UUID` (`let id = UUID()` on each decorator) | **Only while that decorator instance lives** | New UUID every `HistoryItemDecorator(...)` | `SearchMatchDTO.id`, selection, `VisibilityTracker`, SwiftUI `Identifiable` |

### Invariants that must hold

1. `PersistentIdentifier` is the fetch handle; its `StoredItemID` is the same row's correlation identity within the store.
2. Production only indexes committed items whose temporary identity has been replaced by the stable stored identity.
3. After merge/re-decorate, **decorator id changes**. Corpus must `remove(oldDecoratorId)` then `insert(newEntry)`.
4. Never use decorator id as a database key or cross-process id.

### Evidence — decorator identity

```47:47:Maccy/Observables/HistoryItemDecorator.swift
  let id = UUID()
```

### Evidence — stored identity projection

```swift
func storedItemID(for item: HistoryItem) -> StoredItemID {
  item.persistentModelID.id
}
```

---

## 3. Two signature systems (both needed, both named poorly)

| Name | Carries | Role |
|------|---------|------|
| **Index signature** | `SignatureDTO` / `ContentSignatureEntry`: type, size, optional fingerprint | Candidate generation in `SignatureIndex` |
| **Containment signature** | `HistoryItemEngine.Signature` / private `ContentSignature` with value bytes | **Authoritative** `supersedes` / `dataLikelyEqual` |

Index hits **must** be confirmed with containment. Fingerprint equality alone is not enough (`dataLikelyEqual` still does `lhs == rhs` after hash match).

---

## 4. Pipeline aliases

| Alias | Steps |
|-------|--------|
| **Live ingest** | `Clipboard.checkForChangesInPasteboard` → `IngestRequest` → `BackgroundClipboardIngestor.ingest` → `StoreEvent` → `History.consume` |
| **Legacy add** | `History.add` → optional persist → `findSimilarItem` → merge → limit → decorator |
| **Cold load** | `History.load` → unbounded `FetchDescriptor` → sort → decorate all → seed corpus |
| **Search keystroke** | `searchQuery` → debounce 200 ms → empty: legacy `Search`; non-empty: `SearchActor` → `applySearchResults` |
| **Select-out** | `History.select` / `AppState.select` → `Clipboard.copy` → optional synthetic paste → possible re-ingest |

---

## 5. Singleton bus (common coupling)

| Symbol | Role | Approx. call sites (production `Maccy/`) |
|--------|------|------------------------------------------|
| `AppState.shared` | UI session bus | Widespread (Views, History, Clipboard, Intents, …) |
| `History.shared` | History session | AppDelegate, Intents, ContentView via AppState |
| `Storage.shared` | ModelContainer + mainContext | History, Settings, HistoryItem.availablePins, … |
| `Clipboard.shared` | Pasteboard adapter | History, AppState, AppDelegate |
| `VisibilityTracker.shared` | Viewport id set | Decorator appear/disappear, MemoryGovernor |
| `MemoryGovernor.shared` | Pressure handler | AppDelegate attach/start |
| `ApplicationImageCache.shared` | App icons | Decorator init |
| `HistoryItemDecorator.defaultImageProcessor` | Shared ImageProcessor+ThumbnailCache | Decorator default; AppDelegate injects same into ingestor |

**Count:** `rg` finds **171** matches of `AppState|History|Storage|Clipboard.shared` across **26** production Swift files under `Maccy/` (baseline).

---

## 6. Finding IDs

| Prefix | Meaning |
|--------|---------|
| **DS-xxx** | Design-structure findings in `17-findings-catalog.md` |
| Legacy | `07-F-*`, `LT-*`, `IMG-*` in older audit docs — cross-referenced where still valid |

---

## 7. Confidence language

| Level | Meaning |
|-------|---------|
| High | Closed source path; multi-site confirmation |
| Medium | Needs runtime, fault injection, or broader test graph |
| Low | Inference or conflicting docs not fully closed |
