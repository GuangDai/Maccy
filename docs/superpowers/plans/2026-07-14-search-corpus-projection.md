# Actor-Owned Search Corpus Projection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move full-corpus body truncation off the main actor without increasing startup work or the long-lived actor corpus.

**Architecture:** Main projects model state into uncapped Sendable `SearchCorpusSource` COW values. SearchActor receives one operation-level cap, materializes capped `SearchCorpusItem`s inside actor isolation, and stores only those capped entries.

**Tech Stack:** Swift 6 strict concurrency, SwiftData/main-actor decorators, SearchActor, XCTest, GitHub macOS 26 ARM CI.

## Global Constraints

- Never cross an actor boundary with `HistoryItem` or `HistoryItemDecorator`.
- Add no startup scan, fetch, migration, persistent column, or permanently full-body actor storage.
- Preserve all four search modes, order, offsets, body-limit semantics, and incremental corpus mutations.
- Use TDD and CI only; poll every 90 seconds.

---

### Task 1: Lock the new projection seam

**Files:**

- Modify: `MaccyTests/HistorySearchSessionTests.swift`
- Modify: `MaccyTests/SearchCorpusOwnershipTests.swift`

**Interfaces:**

- Consumes: existing session replacement and stateful SearchActor search.
- Produces: desired `SearchCorpusSource`, operation-level `bodyLimit`, and injected `bodyLimitProvider` interfaces.

- [ ] **Step 1: Prove the session sends an uncapped source**

Add a recording backend using the desired `HistorySearchBackend` corpus
signatures. Construct a body longer than `TextLimits.searchBodyMin`, inject that
minimum through `bodyLimitProvider`, call `replaceCorpus`, await the replacement,
and assert the captured source body is byte-for-byte the full body while the
captured limit is the minimum.

```swift
func testReplaceCorpusDefersBodyCappingToBackend() async {
  let body = String(repeating: "a", count: TextLimits.searchBodyMin + 1)
  let item = decorator(title: "item", body: body)
  let state = HistoryListState(decorators: [item])
  let backend = CorpusSourceRecorder()
  let session = HistorySearchSession(
    listState: state,
    backend: backend,
    debounce: nil,
    bodyLimitProvider: { TextLimits.searchBodyMin }
  )

  session.replaceCorpus([item])
  let replacement = await backend.waitForReplacement()

  XCTAssertEqual(replacement.sources.map(\.body), [body])
  XCTAssertEqual(replacement.bodyLimit, TextLimits.searchBodyMin)
}
```

- [ ] **Step 2: Prove SearchActor caps before ownership**

Add a `SearchCorpusSource` helper and replace the actor corpus with a body made
of exactly `searchBodyMin` filler characters followed by `outside-marker`.
Assert the outside marker does not match and a prefix marker does:

```swift
func testOwnedCorpusCapsSourceBodyAtActorBoundary() async {
  let body = "inside-marker" + String(repeating: "x", count: TextLimits.searchBodyMin)
    + "outside-marker"
  await searchActor.replaceCorpus(
    [source(1, "title", body: body)],
    bodyLimit: TextLimits.searchBodyMin
  )

  let inside = await searchActor.search(query: "inside-marker", mode: .exact)
  let outside = await searchActor.search(query: "outside-marker", mode: .exact)

  XCTAssertEqual(ids(inside), [1])
  XCTAssertTrue(outside.isEmpty)
}
```

- [ ] **Step 3: Commit and verify RED**

```bash
git add MaccyTests/HistorySearchSessionTests.swift MaccyTests/SearchCorpusOwnershipTests.swift
git commit -m "test(quality): lock actor-owned corpus projection"
```

Push and run one workflow after the VF-06 master workflow finishes. Accept only
missing source DTO/new backend signature/body-limit-provider failures.

### Task 2: Move projection into SearchActor

**Files:**

- Modify: `Maccy/Search/SearchDTOs.swift`
- Modify: `Maccy/Search/HistorySearchSession.swift`
- Modify: `Maccy/Search/SearchActor.swift`
- Modify: `MaccyTests/HistoryMutationsTests.swift`
- Modify: `MaccyTests/HistorySearchSessionTests.swift`
- Modify: `MaccyTests/SearchCorpusOwnershipTests.swift`

**Interfaces:**

- Consumes: Task 1 desired contracts.
- Produces: source DTO mutation seam and actor-owned capped `SearchCorpusItem` storage.

- [ ] **Step 1: Add the uncapped source DTO**

In `SearchDTOs.swift`, add:

```swift
struct SearchCorpusSource: Equatable, Sendable {
  let id: UUID
  let title: String
  let body: String
}
```

Document that `body` is transient and uncapped; only SearchActor may project it
into an owned `SearchCorpusItem`.

- [ ] **Step 2: Change the backend corpus mutation interface**

Replace the protocol methods with:

```swift
func replaceCorpus(_ sources: [SearchCorpusSource], bodyLimit: Int) async
func insert(_ source: SearchCorpusSource, bodyLimit: Int, at position: Int) async
```

Update every test backend mechanically. Recording backends retain sources and
limits; no-op backends discard them; mutation recorders derive ids from source.

- [ ] **Step 3: Make the session project sources without prefix copies**

Inject:

```swift
@ObservationIgnored private let bodyLimitProvider: @MainActor () -> Int
```

with default `{ Defaults[.searchBodyLimit] }`. Replace `corpusEntry(for:)` with:

```swift
private func corpusSource(for decorator: HistoryItemDecorator) -> SearchCorpusSource {
  SearchCorpusSource(
    id: decorator.id,
    title: decorator.title,
    body: decorator.item.searchText ?? ""
  )
}
```

Capture `bodyLimitProvider()` once in `replaceCorpus`/`insertCorpus` and pass it
with the source values into the serialized backend operation.

- [ ] **Step 4: Materialize capped items inside SearchActor**

Implement both mutation methods over sources. Use one private actor-isolated
projection:

```swift
private func corpusItem(from source: SearchCorpusSource, bodyLimit: Int) -> SearchCorpusItem {
  let cap = TextLimits.clampedSearchBody(bodyLimit)
  return SearchCorpusItem(
    id: source.id,
    title: source.title,
    body: String(source.body.prefix(cap))
  )
}
```

The dictionary remains `[UUID: SearchCorpusItem]`, proving full sources are not
retained after mutation.

- [ ] **Step 5: Commit GREEN**

```bash
git add Maccy/Search MaccyTests/HistoryMutationsTests.swift MaccyTests/HistorySearchSessionTests.swift MaccyTests/SearchCorpusOwnershipTests.swift
git commit -m "refactor(quality): project search corpus inside actor"
```

### Task 3: Verify and integrate

**Files:**

- Modify: `docs/audit/architecture-and-root-causes.md`
- Modify: `docs/superpowers/specs/2026-07-14-search-corpus-projection-design.md`

- [ ] **Step 1: Run the full workflow**

Require project generation, strict lint/build, all unit/UI shards, and text/image
performance shards. Inspect any failure job-first; permit one retry only for a
documented contention flake.

- [ ] **Step 2: Review allocation ownership**

Run `git diff 4d4252a3..HEAD --check`. Search production main-actor code for
`String(...prefix...)`; confirm corpus sources are transient, SearchActor stores
only capped items, and no model/persistent/startup changes were introduced.

- [ ] **Step 3: Push code before evidence**

Fast-forward and push the green code commit to master so its automatic workflow
cannot be suppressed. Then record exact RED/GREEN evidence in a separate
`[skip ci]` commit and push it without a duplicate workflow.
