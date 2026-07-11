# 02 — End-to-End Data Flows (Step-by-Step Traces)

**Baseline:** HEAD `6cd37c8`  
**Purpose:** Trace every major path with **inputs, transforms, validation, ownership, side effects, outputs, and failure modes**.  
**Do not skim:** each numbered step is a real code boundary.

---

# Flow A — Live ingest (external copy → history UI)

Production wiring (`AppDelegate.applicationWillFinishLaunching`):

```82:88:Maccy/AppDelegate.swift
    Clipboard.shared.ingestor = BackgroundClipboardIngestor(
      modelContainer: Storage.shared.container,
      image: HistoryItemDecorator.defaultImageProcessor,
      now: { Date() },
      onEvent: { @MainActor event in History.shared.consume(event) }
    )
    Clipboard.shared.start()
```

---

## A.0 Timer observation

| Field | Detail |
|-------|--------|
| **Entry** | `Clipboard.start()` |
| **Mechanism** | `Timer.scheduledTimer(timeInterval:max(0.1, Defaults[.clipboardCheckInterval]), target:self, selector:#selector(checkForChangesInPasteboard), …)` |
| **Isolation** | `@MainActor class Clipboard` |
| **Evidence** | `Clipboard.swift` ~71–79 |
| **Issues** | No `tolerance`; default run-loop mode (not `.common`) — polling may stall during tracking (DS-024) |

---

## A.1 changeCount gate

| | |
|--|--|
| **Code** | `checkForChangesInPasteboard` start |
| **Input** | `pasteboard.changeCount`, `self.changeCount` |
| **Action** | Equal → return. Unequal → `changeCount = pasteboard.changeCount` **before** later gates finish work |
| **Side effect** | Consumes the change for this process even if later gates ignore the copy |
| **Output** | Proceed or stop |
| **Issue** | One Task per change; no coalesce (DS-020) |

---

## A.2 Paste-stack interrupt

| | |
|--|--|
| **Condition** | Pasteboard items do **not** contain `.fromMaccy` |
| **Action** | `AppState.shared.history.interruptPasteStack()` |
| **Coupling** | Clipboard → AppState → History (**common coupling**, DS-006) |
| **Meaning** | External copy aborts multi-paste sequence |

---

## A.3 User ignore switches

| | |
|--|--|
| **Reads** | `Defaults[.ignoreEvents]`, `Defaults[.ignoreOnlyNextEvent]` |
| **Action** | If ignoring: maybe clear “next only” flags; **return** |
| **Note** | changeCount already advanced → this change never retries |

---

## A.4 Fast type / app gates (main thread)

| Gate | Logic | Evidence |
|------|-------|----------|
| Types | `shouldIgnore(Set(pasteboard.types))`: disjoint from enabled **or** intersects ignored/concealed/transient | `Clipboard.swift` ~221–223, 296–301 |
| App | frontmost `bundleIdentifier` vs ignore list / allow-list flip | ~225–227, 306–311 |

**Important:** Comments state actor `filterContents` is **authoritative**. Fast path can drop early; if fast path allows and actor drops → no event (OK).  
**Dead code:** `shouldIgnore(_ item:)`, `isEmptyString`, `richText` are **private and never called** (DS-008) — only type/app overloads are used.

---

## A.5 Snapshot → `IngestRequest`

| Step | Transform |
|------|-----------|
| 1 | `NSPasteboardSource().snapshot()` walks `pasteboardItems`, `data(forType:)` → `[PasteboardItemSnapshot]` with `[String: Data]` |
| 2 | Flatten to `[ContentDTO(type, value, fingerprint: nil, size: bytes.count)]` |
| 3 | Empty → return nil |
| 4 | `IngestRequest(source: CopyOrigin(changeCount), contents, application: frontmost bundle id, now: Date())` |

| Field | Value |
|-------|--------|
| **Ownership** | `Data` copies owned by request; no further NSPasteboard reads required for ingest body |
| **Not done here** | Type filter, max size, fingerprints (left nil intentionally) |
| **Evidence** | `Clipboard.ingestRequestFromPasteboard` ~252–273; `PasteboardSource.swift` |

---

## A.6 Async dispatch

```text
Task { await ingestor.ingest(request) }
```

| | |
|--|--|
| **If `ingestor == nil`** | Gates ran; **no write** (legacy/unwired tests) |
| **Ordering** | Multiple Tasks may queue; actor serializes `ingest` |
| **Backpressure** | None |

---

## A.7 Actor: MainActor hop (filter + title + body + limit)

> **Current update (D2, `a487276`, `70e1d23`):** this unconditional block no
> longer exists. `Clipboard` captures live Defaults as a Sendable
> `IngestPolicy`; the actor performs pure filtering and ordinary text projection.
> `IngestMainActorPlan` routes only reachable small RTF/HTML parsing to main.
> Heavy plain-text and RTF fixtures characterize the split, and the existing
> RTF ingest test guards the off-main trap regression.

```155:172:Maccy/Ingest/ClipboardIngestor.swift
    let mainWork = await MainActor.run { () -> IngestMainWork in
      let config = Self.ingestConfig()
      let filtered = filterContents(
        request.contents, application: request.application, config: config
      )
      return IngestMainWork(
        filtered: filtered,
        title: Self.title(for: filtered),
        searchText: Self.searchableBody(for: filtered),
        historyLimit: max(1, Defaults[.size])
      )
    }
```

### A.7.1 `ingestConfig()` — configuration snapshot

Builds `IngestConfig` from Defaults + **hardcoded** UTI raw strings for supported/ignored types (duplicated from `Clipboard` private sets) — **DS-008**.

### A.7.2 `filterContents` rule order (pure function, AppKit for RTF/HTML)

Documented order in `IngestFilter.swift`:

1. Application ignore / allow-list  
2. Global type gate (enabled / ignored markers)  
3. Empty-string rule (no rich text + whitespace-only string within title limit)  
4. `ignoreRegexp` (recompiled each call; no NSCache unlike Clipboard’s dead path)  
5. Per-type keep set: drop disabled supported types; keep unknown UTIs; strip `dyn.` / `com.microsoft.ole.source.`; Word link subtraction  
6. Drop entries with `value.count > maxValueSize`  

**Output:** ordered surviving `[ContentDTO]`. Empty → `IngestResult(event: nil)` (no write, no `onEvent`).

### A.7.3 Title / searchText

Temporary uninserted `HistoryItemContent` rows fed into `HistoryItemEngine.generateTitle` / `searchableBody` (NSAttributedString on main).  
**DS-011 baseline:** last major main-thread cost on copy path. Resolved by the
selective D2 routing described above.

---

## A.8 Build `@Model` on actor context

```text
HistoryItem(contents: map ContentDTO → HistoryItemContent)
application, firstCopiedAt, lastCopiedAt, title, searchText assigned
```

`HistoryItemContent.init` sets `fingerprint = fingerprintIfLarge(value)` for new rows.

**Not saved yet.**

---

## A.9 Lazy SignatureIndex build (once, O(n))

```text
ensureDedupIndexInitialized():
  if !dedupIndexInitialized:
    fetch all HistoryItem on actor ModelContext
    register each into SignatureIndex + persistentIDByItemID
    dedupIndexInitialized = true
```

| Risk | First ingest after launch can pay full-table cost on actor |
| State | Lives only in actor; **not** updated by UI deletes (DS-009) |

---

## A.10 Find duplicate

```text
signature = item.duplicateSignature          // Engine containment signature
entries = contents → ContentSignatureEntry   // may re-hash large blobs
for candidateID in signatureIndex.candidates(forEntries: entries):
  pid = persistentIDByItemID[candidateID]
  candidate = modelContext.model(for: pid) as? HistoryItem
  backfillMissingFingerprints(candidate)     // pending column writes
  if candidate.supersedes(signature): return candidate
```

| Fast path | No shared entries → no candidates → no scan |
| Confirm | `supersedes` → `dataLikelyEqual` (size, fingerprints, then `==`) |
| Backfill | **Only candidates**; rows never hit as candidates stay nil-fp (DS-FINGERPRINT-SCOPE) |
| Gap vs legacy | No `sessionLog` / `isModified` (documented parity gap) |

---

## A.11 Merge fields (if dup)

```text
item.contents ← copies of dup.contents (new HistoryItemContent rows)
firstCopiedAt, numberOfCopies, pin, title, searchText from dup
application unless fromMaccy
lastCopiedAt ← timestamp
```

Evidence: `mergeFields(from:into:timestamp:)` in `ClipboardIngestor.swift`.

---

## A.12 Single-transaction commit

```text
modelContext.transaction {
  fetch unpinned order lastCopiedAt desc
  if dup: delete dup; record ItemID
  if unpinned.count > limit-1: delete oldest excess; record ItemIDs
  insert item
}
processPendingChanges(); save()
```

| Failure | `logger.error`; return `event: nil`; **index not maintained** (maintain runs only after success) |
| Success | `deletedItemIDs` returned |

**Invariant:** insert + dup delete + size trim share one save. **Do not split.**

---

## A.13 Index maintain + event

```text
maintainDedupIndex(inserted, deleted)
event = .added(snapshot(of: item)) | .merged(snapshot(of: item))
await onEvent(event)   // production: History.shared.consume on MainActor
```

### `snapshot(of:)` costs

Builds `ItemID`, `persistentID`, metadata, `textPreview` via `previewableTextPrefix` (may parse rich text), `imageFingerprint` via `imageData` (may read Handoff file). Runs on actor after save.

---

## A.14 Main thread: `History.consume`

```349:357:Maccy/Observables/History.swift
  func consume(_ event: StoreEvent) {
    switch event {
    case .added(let snapshot), .merged(let snapshot):
      insertIncrementally(snapshot)
    case .removed, .cleared:
      reconcileWithStore()
    }
  }
```

Ingest today only emits `.added` / `.merged`.

### A.14.1 `insertIncrementally` (step detail)

| # | Action | Failure → |
|---|--------|-----------|
| 1 | `persistentID == nil` | full `reconcileWithStore` |
| 2 | Find existing decorator same `persistentModelID`; `cleanup`; remove; remember decorator.id for corpus | — |
| 3 | `model(for: persistentID) as? HistoryItem` **and** `model.title == snapshot.title` | full reconcile |
| 4 | `HistoryItemDecorator(model)` — **new decorator UUID** | — |
| 5 | `BinaryInsertion.index` with `sorter.areInIncreasingOrder` | — |
| 6 | `all.insert` at position | — |
| 7 | `Task { searchActor.remove(old); insert(entry, at: position) }` fire-and-forget | corpus may lag |
| 8 | `syncAllToStore()` | see A.14.2 / **DS-002** |
| 9 | `refreshVisibleItems()` | may kick search |
| 10 | Maybe `navigator.select` first unpinned/pinned | AppState coupling |
| 11 | `popup.needsResize = true` | AppState coupling |

**Title equality guard risk:** If store title and snapshot title diverge (bug or partial update), path falls back to full reconcile (safe but expensive). If `model(for:)` returns empty shell with empty title while snapshot has title → reconcile.

### A.14.2 `syncAllToStore` — critical

```420:423:Maccy/Observables/History.swift
  private func syncAllToStore() {
    let storeIDs = Set(
      (try? Storage.shared.context.fetchIdentifiers(FetchDescriptor<HistoryItem>())) ?? []
    )
```

| Success | Remove decorators whose `persistentModelID` ∉ storeIDs; remove from search corpus |
| **Failure** | `try?` → `nil` → `?? []` → **empty set** → **every** decorator treated as missing → **UI history cleared** |
| Empty store | Same code path as failure — legitimate clear after true empty DB |

**DS-002:** Failure and empty store are **indistinguishable**. Confidence High on static path; Medium that fetchIdentifiers throws in practice.

---

## A.15 Visible list

| Condition | Action |
|-----------|--------|
| `searchQuery.isEmpty` | `items = all`; shortcuts |
| else | `performSearch()` async |

---

## A.16 Flow A summary diagram

```text
NSPasteboard
  → [main] changeCount + ignore gates
  → [main] snapshot → IngestRequest [ContentDTO, fp=nil]
  → Task
  → [main hop] IngestConfig + filterContents + title + searchText + limit
  → [actor] HistoryItem + SignatureIndex + supersedes + single txn
  → StoreEvent ItemSnapshotDTO
  → [main] insertIncrementally / reconcile
       → all[] + SearchActor corpus + AppState chrome side effects
```

### Flow A findings map

| DS | Where |
|----|--------|
| DS-006/007 | A.2, A.14 steps 10–11 |
| DS-008 | A.4 dead helpers; A.7.1 hardcoded UTIs |
| DS-009 | A.9 index vs UI delete |
| DS-011 | A.7 |
| DS-019 | snapshot ItemID |
| DS-020 | A.1/A.6 |
| DS-002 | A.14.2 |
| DS-024 | A.0 |

---

# Flow B — Cold load / prewarm

## B.1 Triggers

| Trigger | Code |
|---------|------|
| Popup open | `ContentView.task`: if `items.isEmpty` → `try? await history.load()` (`ContentView.swift` ~62–67) |
| Hotkey prewarm | `AppState.prewarmVisibleWindow` → `try? await history.load()` |
| Defaults sort/pin | `loadAfterDefaultsChange` → `load()` |

**Swallowed errors:** `try?` on load (DS-LOAD-ERR).

## B.2 `History.load` steps

```269:284:Maccy/Observables/History.swift
  func load() async throws {
    let descriptor = FetchDescriptor<HistoryItem>()
    let results = try Storage.shared.context.fetch(descriptor)
    all = autoreleasepool { sorter.sort(results).map { HistoryItemDecorator($0) } }
    items = all
    limitHistorySize(to: historySizeLimit)
    updateShortcuts()
    await searchActor.replaceCorpus(all.map { corpusEntry(for: $0) })
    Task {
      AppState.shared.popup.needsResize = true
    }
  }
```

| # | Step | Cost / note |
|---|------|-------------|
| 1 | Unbounded fetch **no** `fetchLimit` / `sortBy` / `propertiesToFetch` | Full table into mainContext |
| 2 | `sorter.sort` on main | Pin partition + algorithm; faults properties |
| 3 | Map every row → `HistoryItemDecorator` | App icon cache; observation sync pin/title |
| 4 | `items = all` | Full list published to UI |
| 5 | `limitHistorySize` | **Per-item `delete`** if over size (DS-014) |
| 6 | Shortcuts | First 9 unpinned digits |
| 7 | Replace entire search corpus | |
| 8 | needsResize | |

**Does not call** `VisibleWindowLoader.fetchWindow` (exists in `Storage+Background.swift`, tested only) — **DS-004**.

## B.3 Memory coupling

Full fetch + later content/image access keeps `_KKMDBackingData` in mainContext (see 2026-06-27 memory suite). Structural, not a leak detector false positive.

## B.4 Parallel read API (unwired)

`VisibleWindowLoader.fetchWindow` → sort + `fetchLimit` → `snapshot(of:)` → split visible/tail.  
**Product load path never uses it** → two mental models for “read history”.

---

# Flow C — Search

## C.1 Input

`searchQuery` `didSet` → `searchQueryContinuation.yield` → consumer:

```text
removeDuplicates().debounce(for: .milliseconds(200)) → performSearch()
```

## C.2 Empty query (synchronous legacy path)

```text
invalidateInFlightSearch()
updateItems(search.search(string: "", within: all))  // legacy Search class
navigator.select(unpinned first)
popup.needsResize
```

Uses **`Search`**, not `SearchActor` — **DS-010**.

## C.3 Non-empty query

```text
searchGeneration &+= 1
cancel prior searchTask
Task {
  matches = await searchActor.search(query, mode: Defaults[.searchMode])
  applySearchResults(matches, query, generation)
}
```

Corpus **not** sent per keystroke; actor owns corpus.

## C.4 SearchActor matching

| Mode | Behavior |
|------|----------|
| exact | title substring else body; Character offsets; `inBody` |
| regexp | unsafe pattern reject; title shortened; body full firstMatch |
| fuzzy | Fuse 0.7; title then body prefix; title-first sort |
| mixed | exact → (meta chars? regexp) → fuzzy, short-circuit |

Body text = capped `searchText` at corpus build time (`corpusEntry`).

## C.5 `applySearchResults`

| # | Step |
|---|------|
| 1 | Drop if generation mismatch |
| 2 | For each DTO: `all.first { $0.id == dto.id }` — **O(n) per match** (DS-012) |
| 3 | `inBody` → clear title highlight; `setPreviewHighlight` |
| 4 | else if `decorator.title == dto.title` → title highlight |
| 5 | else clear highlights (stale title) |
| 6 | `items = rebuilt`; shortcuts; navigator; needsResize |

## C.6 Corpus maintenance matrix

| History op | Corpus update |
|------------|---------------|
| load | `replaceCorpus` |
| insertIncrementally | remove old decorator id + insert at index |
| reconcileWithStore | `replaceCorpus` |
| syncAll removals | `remove(ids)` |
| clear / clearAll / delete | remove / clear |
| togglePin reorder | remove + insert at new index |
| searchBodyLimit Defaults | replace + refresh |

**DS-013:** `togglePin` does **not** call `invalidateInFlightSearch` — in-flight search may apply against old order.

**Async lag:** corpus `Task`s fire-and-forget; comments admit one-item staleness.

---

# Flow D — Select / paste out

## D.1 Entry points

- `AppState.select()`: multi → paste stack; single history → `history.select`; footer actions; empty selection + query → `Clipboard.copy(searchQuery)`
- Keyboard/mouse via `NavigationManager` + `KeyHandlingView`

## D.2 `History.select`

```text
read modifier flags → HistoryItemAction
close popup (AppState)
Clipboard.copy(item, removeFormatting?)
optional Clipboard.paste()  // CGEvent ⌘V
searchQuery = ""
```

## D.3 `Clipboard.copy(HistoryItem)`

```text
clearContents
optional clearFormatting (keep string + fileURL)
setData for each content type except fileURL loop
writeObjects(fileURLs)
setString("", .fromMaccy)
setString(application, .source)
sync() // special apps focus dance
Task { Notifier; checkForChangesInPasteboard() }
```

## D.4 Re-ingest

- `.fromMaccy` present → **no** paste-stack interrupt (A.2)
- changeCount still advances → may run full Flow A again
- Dedup typically merges (same contents) updating copies/timestamps

**Cycle:** UI select → write pasteboard → observe self → actor merge. Relies on markers + supersedes. Control/timing coupling between Clipboard and History.

---

# Flow E — Delete / clear

## E.1 Single delete

```text
invalidateInFlightSearch
persistence.delete(item)  // mainContext delete+save
cleanup decorator
remove from all/items
sessionLog scrub
searchActor.remove([decorator.id])
shortcuts + needsResize
```

**Not done:** notify ingest actor SignatureIndex (DS-009).

## E.2 clear (keep pins) / clearAll

Predicate deletes on main context; rebuild `all`; corpus remove/clear; `Clipboard.clear()` if setting; close popup.

## E.3 Writers compared

| Writer | Context | Events |
|--------|---------|--------|
| Ingest trim | background txn | No `.removed`; UI learns via `syncAllToStore` |
| UI delete/clear | main persistence | Local array ops only |
| Legacy add limit | main per-item delete | — |

---

# Flow F — Legacy `History.add` (tests / adapter)

```text
optional insertIntoStorage
mergeDuplicateIfNeeded → findSimilarItem (fetchAll + O(n) supersedes + isModified(sessionLog))
limitHistorySize
sessionLog[Clipboard.shared.changeCount] = persistentModelID
insertDecorator (may full-sort)
refreshVisibleItems + needsResize
```

| Used by | `HistoryTests`, pin tests, popup tests, `PerfHistoryFactory`, `MainActorIngestorAdapter` |
| Not used by | Production AppDelegate path |
| Adapter result | `IngestResult(event: nil, metrics: .zero)` — **no StoreEvent** |

**DS-003:** Two write semantics in one codebase.

---

# Flow G — Images (sidecar)

```text
viewport onAppear → ensureThumbnailImage
  lazy item.imageData (fault blob / Handoff file)
  Task: await ImageProcessor.thumbnail → ThumbnailCache → Downsampler
  publish thumbnailImage on main
lead selection → ensurePreviewImage / asyncGetPreviewImage (uncached)
scroll out → releaseTransientImages(.scrollOut) keeps thumbnail
memory pressure → MemoryGovernor releases non-visible heavy state
lead change → cancelPreviewGeneration (NavigationManager.didSet)
```

Shared `defaultImageProcessor` injected into ingestor at launch (ingest path does not currently decode for titles).

---

# Cross-flow invariants

1. `@Model` does not cross actors; DTOs do.  
2. mainContext ≠ actor ModelContext; shared store.  
3. Decorator UUID ≠ PersistentIdentifier ≠ ItemID.  
4. Search offsets are Character-based.  
5. SignatureIndex is candidate-only; supersedes is authority.  
6. Production history **writes** prefer actor single txn; UI mutations still main.  
7. Multi-projection consistency is **best-effort**, not one transactional bus.

---

# Transform necessity

| Transform | Necessary? |
|-----------|------------|
| Pasteboard → ContentDTO | **Yes** (leave AppKit / cross actor) |
| ContentDTO → HistoryItemContent | **Yes** (persistence shape) |
| HistoryItem → ItemSnapshotDTO | **Yes** (event payload) |
| Snapshot → model(for:) again | **Yes under current design** (main-context identity) |
| Dual search engines | **No** (empty-query UX can short-circuit without full Search class) |
| Full load vs window loader | Windowed path intended; **not integrated** |
| Three IDs | Decorator id for UI is fine; ItemID indirection is the fragile piece |

---

# Suggested conceptual target flow (not implemented)

```text
Capture(raw DTO)
  → PureFilter(config snapshot)     // minimize MainActor
  → Dedup(index + supersedes)
  → Persist(single txn) → DomainEvent{added|merged|removed|cleared}
  → Projectors: List / SearchCorpus / SignatureIndex / optional thumbs
```

UI mutations should emit the **same** event kinds so all projections update.
