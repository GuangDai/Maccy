# History B2–B5 Deep-Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:executing-plans` to implement this plan task-by-task. Do not use
> subagents in this repository unless the user explicitly changes the current
> no-delegation instruction. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 979-line `History` god object with a stable observable
facade over cohesive list, search, store-projection, and mutation modules; delete
the dead legacy writer; centralize search invalidation; and invert AppState UI
effects without changing user-visible clipboard behavior.

**Architecture:** Delete production-dead behavior before extracting anything.
Then route UI effects outward as values, extract observable list state with an
Observation proof, move search and store projection behind small interfaces,
and finally extract user mutations. `History` remains the compatibility facade.

**Tech Stack:** Swift 6.0 complete strict concurrency, AppKit, SwiftUI
Observation, SwiftData, AsyncAlgorithms, XCTest, XcodeGen 2.45.4, GitHub Actions
macOS 26 arm64.

## Global Constraints

- There is no local Apple toolchain. All red/green/build/lint evidence comes
  from the `macOS 26 ARM CI` workflow; never run local `xcodebuild`/SwiftLint.
- Run only one workflow at a time. Poll at least 30 seconds apart.
- Cancel remaining matrix jobs immediately after a real compile/test failure.
- Do not rerun a known runner-contention UI/perf flake.
- Pure documentation commits do not trigger CI.
- Add/remove source files through `project.yml` discovery and apply the
  workflow-generated `committed-output.diff`; never hand-write pbxproj UUIDs.
- One small roadmap step per commit. Structure and behavior changes use
  separate commits unless the test-first cycle itself requires both.
- Preserve complete retained history/search semantics. Do not introduce
  windowing or reduce startup rate to save memory.
- No `@unchecked Sendable`, `nonisolated(unsafe)`, new lint disables, raised
  length thresholds, generic event bus, repository pyramid, or singleton
  wrapper adapter.
- Preserve the user's dirty primary worktree (`CLAUDE.md`, `AGENTS.md`,
  `PR_DESCRIPTION.md`) by working only in the isolated feature worktree.

---

## Task 1: B3 live-path test seeding interface

**Files:**
- Modify: `MaccyTests/Support/HistoryBuilder.swift`
- Modify: `MaccyTests/SupportTests.swift`

**Interfaces:**
- Produces:
  `HistoryTestDriver.seed(_:in:) throws -> HistoryItemDecorator` and
  `HistoryTestDriver.seed(_:in:) throws -> [HistoryItemDecorator]`.
- Guarantees: one main-context save per batch, one `.added` consume per item,
  returned decorators resolve by `persistentModelID`, and no legacy `add` call.

- [ ] **Step 1: Write the failing driver contract test**

Add to `SupportTests`:

```swift
@MainActor
func testHistoryTestDriverSeedsThroughCommittedConsumePath() throws {
  History.shared.clearAll()
  let item = HistoryBuilder()
    .withContent(type: "public.utf8-plain-text", value: Data("seed".utf8))
    .build()

  let decorator = try HistoryTestDriver.seed(item)

  XCTAssertTrue(History.shared.all.contains { $0 === decorator })
  XCTAssertEqual(decorator.item.persistentModelID, item.persistentModelID)
  XCTAssertEqual(try Storage.shared.context.fetchCount(FetchDescriptor<HistoryItem>()), 1)
}
```

- [ ] **Step 2: Commit and verify RED on CI**

```sh
git add MaccyTests/SupportTests.swift
git commit -m "test(b3): define committed consume seeding interface"
git push -u origin b2-b5-history
gh workflow run "macOS 26 ARM CI" --ref b2-b5-history
```

Expected: unit compile fails because `HistoryTestDriver` does not exist. Cancel
the remaining matrix once that exact failure appears.

- [ ] **Step 3: Implement the minimal driver**

Append to `HistoryBuilder.swift`:

```swift
@MainActor
enum HistoryTestDriver {
  enum SeedError: Error { case missingDecorator }

  static func seed(
    _ item: HistoryItem,
    in history: History = .shared
  ) throws -> HistoryItemDecorator {
    let seeded = try seed([item], in: history)
    guard let decorator = seeded.first else {
      throw SeedError.missingDecorator
    }
    return decorator
  }

  static func seed(
    _ items: [HistoryItem],
    in history: History = .shared
  ) throws -> [HistoryItemDecorator] {
    let context = Storage.shared.context
    items.forEach(context.insert)
    context.processPendingChanges()
    try context.save()
    for item in items {
      history.consume(.added(snapshot(of: item)))
    }
    let byID = Dictionary(
      uniqueKeysWithValues: history.all.map { ($0.item.persistentModelID, $0) }
    )
    return try items.map {
      guard let decorator = byID[$0.persistentModelID] else {
        throw SeedError.missingDecorator
      }
      return decorator
    }
  }
}
```

- [ ] **Step 4: Commit and run the full GREEN matrix**

```sh
git add MaccyTests/Support/HistoryBuilder.swift
git commit -m "test(b3): seed History through committed consume path"
git push origin b2-b5-history
gh workflow run "macOS 26 ARM CI" --ref b2-b5-history
```

Expected: generation, strict lint, unit, UI, and perf shards pass.

---

## Task 2: B3 migrate ordinary History consumers off `add`

**Files:**
- Modify: `MaccyTests/HistoryTests.swift`
- Modify: `MaccyTests/HistoryPinPersistenceTests.swift`
- Modify: `MaccyTests/PopupTests.swift`
- Modify: `MaccyTests/PerfHistoryFactory.swift`
- Modify: `MaccyTests/PerfHistoryFactoryTests.swift` only if assertions need
  async/throwing propagation.

**Interfaces:**
- Consumes: Task 1 `HistoryTestDriver.seed`.
- Produces: no `history.add` reference in these files; tests exercise committed
  store + `consume`, or `load()` for load-size behavior.

- [ ] **Step 1: Migrate simple setup calls**

Replace `history.add(item)` with `try HistoryTestDriver.seed(item, in: history)`.
Make affected tests `throws`; active-query tests become `async throws` and call
`await history.waitForInFlightSearch()` before asserting filtered `items`.

- [ ] **Step 2: Move size-limit tests to the production load path**

For `testMaxSize*`, insert a batch into `Storage.shared.context`, save once, call
`try await history.load()`, and assert the same survivors. Do not reproduce the
deleted legacy add algorithm in test support. The actor's per-copy trim remains
covered by `BackgroundClipboardIngestorTests`.

- [ ] **Step 3: Bulk-seed perf factories**

Build each scenario's `[HistoryItem]`, then call
`try HistoryTestDriver.seed(items, in: history)` once. Preserve timestamps and
interleaving exactly so performance corpora keep the same ordering/content.

- [ ] **Step 4: Verify static scope and commit**

```sh
rg -n "history\.add\(" \
  MaccyTests/HistoryTests.swift \
  MaccyTests/HistoryPinPersistenceTests.swift \
  MaccyTests/PopupTests.swift \
  MaccyTests/PerfHistoryFactory.swift
git diff --check
git add MaccyTests
git commit -m "test(b3): migrate History consumers to committed ingest projection"
git push origin b2-b5-history
gh workflow run "macOS 26 ARM CI" --ref b2-b5-history
```

Expected: `rg` returns no matches; full matrix passes.

---

## Task 3: B3 retire legacy-only assertions

**Files:**
- Modify: `MaccyTests/HistoryTests.swift`
- Modify: `MaccyTests/IngestErrorPropagationTests.swift`
- Modify: `MaccyTests/ClipboardIngestorTests.swift`
- Modify: `docs/audit/2026-07-12-history-b2-b5-design.md`

**Interfaces:**
- Produces: no test depends on sessionLog modification merge,
  `shouldInsertItemsInAdd`, or `MainActorIngestorAdapter.historyItem`.

- [ ] **Step 1: Prove replacement coverage before deletion**

Use `rg` to map each legacy assertion to existing actor coverage:

```sh
rg -n "duplicate|supersed|size trim|numberOfCopies|fromMaccy" \
  MaccyTests/BackgroundClipboardIngestorTests.swift
```

Record exact replacement test names in the B3 section of the design doc.

- [ ] **Step 2: Delete only production-dead tests**

Remove `HistoryTests` cases whose subject is legacy duplicate/sessionLog merge,
the `insert` failure case configured through `shouldInsertItemsInAdd`, and the
static adapter construction test. Keep clear/delete/pin/search/command tests.

- [ ] **Step 3: Verify zero legacy test dependency and commit**

```sh
rg -n "shouldInsertItemsInAdd|sessionLog|MainActorIngestorAdapter|history\.add\(" MaccyTests
git diff --check
git add MaccyTests docs/audit/2026-07-12-history-b2-b5-design.md
git commit -m "test(b3): retire production-dead legacy writer assertions"
git push origin b2-b5-history
gh workflow run "macOS 26 ARM CI" --ref b2-b5-history
```

Expected: no matches and full matrix green. The doc is bundled with the code/test
change; do not trigger a separate docs-only workflow.

---

## Task 4: B4 delete the legacy writer

**Files:**
- Modify: `Maccy/Observables/History.swift`
- Modify: `Maccy/Ingest/ClipboardIngestor.swift`
- Modify: `docs/audit/2026-07-10-master-roadmap.md`
- Modify: `docs/audit/2026-07-09-design-audit-verification/01-verdict-matrix.md`
- Modify: `docs/audit/2026-07-09-design-structure-audit/17-findings-catalog.md`

**Interfaces:**
- Removes: `History.add`, `insertIntoStorage`, `mergeDuplicateIfNeeded`,
  `insertDecorator`, `findSimilarItem`, `isModified`, `sessionLog`,
  `shouldInsertItemsInAdd`, and `MainActorIngestorAdapter`.
- Preserves: live `BackgroundClipboardIngestor → StoreEvent → History.consume`.

- [ ] **Step 1: Delete the production-dead code**

Remove the symbols above, their initializer parameter/default helper, sessionLog
maintenance from clear/delete, legacy-only imports, and comments that claim the
adapter is a runtime path. Do not edit actor dedup or transaction behavior.

- [ ] **Step 2: Verify deletion and source size**

```sh
rg -n "History\.shared\.add|func add\(|sessionLog|shouldInsertItemsInAdd|MainActorIngestorAdapter|findSimilarItem|mergeDuplicateIfNeeded" Maccy MaccyTests
wc -l Maccy/Observables/History.swift
git diff --check
```

Expected: no matches; `History.swift` materially smaller than 979 lines.

- [ ] **Step 3: Commit and run full CI**

```sh
git add Maccy MaccyTests docs/audit
git commit -m "refactor(b4): delete legacy History writer"
git push origin b2-b5-history
gh workflow run "macOS 26 ARM CI" --ref b2-b5-history
```

Expected: full matrix green; B3/B4 and DS-003/016/new-ingest-dualpath-3 closed.

---

## Task 5: B2a invert History UI effects

**Files:**
- Create: `Maccy/Observables/HistoryUIEffect.swift`
- Create: `MaccyTests/HistoryUIEffectTests.swift`
- Modify: `Maccy/Observables/History.swift`
- Modify: `Maccy/Observables/AppState.swift`
- Generated: `Maccy.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces:

```swift
@MainActor
enum HistoryUIEffect {
  case closePopup
  case resizePopup
  case select(HistoryItemDecorator?)
  case highlightFirst
  case scrollTo(UUID)
}

typealias HistoryUIEffectSink = @MainActor (HistoryUIEffect) -> Void
```

- `History.configureUIEffectSink(_:)` installs the owner-provided sink.
- `AppState.init` installs a closure capturing that instance weakly and applies
  effects to `popup`/`navigator`; it never uses `AppState.shared` in the sink.

- [ ] **Step 1: Write RED recording-sink tests**

Cover at least: consume-empty-query emits select+resize, clear emits
close+resize, search apply emits highlight+resize, and unpin emits scroll. The
tests refer to missing `HistoryUIEffect` / `configureUIEffectSink`, producing the
expected compile RED.

- [ ] **Step 2: Add files and regenerate the project mechanically**

Push the red commit, run the workflow, download
`xcodeproj-generation-<run>-1/committed-output.diff`, apply it with `git apply`,
and commit only the generated pbxproj as:

```text
build(b2a): regenerate project for History UI effects
```

Rerun to obtain the actual missing-interface RED, then cancel remaining shards.

- [ ] **Step 3: Implement effect values and owner sink**

Replace every `AppState.shared` use in `History.swift` with `emit(effect)`. Add
an `AppState.applyHistoryUIEffect(_:)` switch and configure it after popup and
navigator initialization. Preserve deferred `Task` timing only where the old
code deferred it; do not introduce a general event bus or protocol adapter.

- [ ] **Step 4: Verify inversion and GREEN**

```sh
rg -n "AppState\.shared" Maccy/Observables/History.swift Maccy/Observables/HistoryUIEffect.swift
git diff --check
git add Maccy MaccyTests Maccy.xcodeproj/project.pbxproj
git commit -m "refactor(b2a): invert History UI effects"
git push origin b2-b5-history
gh workflow run "macOS 26 ARM CI" --ref b2-b5-history
```

Expected: no matches and full matrix green.

---

## Task 6: B5 mutation chokepoint plus observable list state

**Files:**
- Create: `Maccy/Observables/HistoryListState.swift`
- Create: `MaccyTests/HistoryListStateTests.swift`
- Modify: `Maccy/Observables/History.swift`
- Generated: `Maccy.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces `@MainActor @Observable final class HistoryListState` with:

```swift
private(set) var items: [HistoryItemDecorator]
@ObservationIgnored private(set) var all: [HistoryItemDecorator]
func replaceAll(_ decorators: [HistoryItemDecorator])
func insert(_ decorator: HistoryItemDecorator, at index: Int)
func removeStoredIDs(_ ids: Set<PersistentIdentifier>) -> [HistoryItemDecorator]
func remove(_ decorator: HistoryItemDecorator) -> Bool
func publishVisible(_ decorators: [HistoryItemDecorator])
```

- Structural methods invoke one `willMutate` closure before changing `all`;
  `publishVisible` does not invalidate the search it is applying.
- The facade exposes compatible `items`/`all` computed properties while
  production code uses named list-state methods.

- [ ] **Step 1: Write RED module tests**

Test that each structural call invokes `willMutate` once, visible publication
does not invoke it, persistent-ID removal returns exactly removed decorators,
and `withObservationTracking { history.items }` fires when the nested state
publishes a new visible list.

- [ ] **Step 2: Regenerate project and verify missing-type RED**

Follow Task 5's generated-diff process; commit the pbxproj separately, then run
the unit shard and confirm missing `HistoryListState`/initializer behavior.

- [ ] **Step 3: Implement and migrate list writes**

Configure `willMutate` to call the current `invalidateInFlightSearch`. Replace
all direct structural `all =`, `all.insert`, and `all.remove*` operations with
the named module interface. Search-result application uses `publishVisible`.
Keep compatibility setters only under `#if DEBUG` if production has no writer.

- [ ] **Step 4: Run full GREEN and commit evidence**

```sh
git add Maccy MaccyTests Maccy.xcodeproj/project.pbxproj
git commit -m "refactor(b5): centralize History list mutation invalidation"
git push origin b2-b5-history
gh workflow run "macOS 26 ARM CI" --ref b2-b5-history
```

Expected: full matrix green; B5 generation chokepoint no longer relies on every
caller remembering an invalidation call.

---

## Task 7: B2b/C3 extract the search session

**Files:**
- Create: `Maccy/Search/HistorySearchSession.swift`
- Create: `MaccyTests/HistorySearchSessionTests.swift`
- Modify: `Maccy/Observables/History.swift`
- Delete: `Maccy/Search/Search.swift` after its empty-query role is removed
- Modify existing search tests as required
- Generated: `Maccy.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces a main-actor module owning query stream/continuation/consumer,
  generation/task, `SearchActor`, corpus, and `[UUID: Decorator]` lookup.
- Interface: `query`, `generation`, `wait()`, `refresh(mode:)`, `invalidate()`,
  `replaceCorpus`, `insertCorpus`, `removeCorpus`, `clearCorpus`.
- It publishes visible results to `HistoryListState` and emits UI effects.

- [ ] **Step 1: Write RED search-session tests**

Cover empty-query synchronous full-list publication, generation rejection of a
late result, O(1) ID lookup behavior through duplicate/missing IDs, corpus
insert/remove ordering, body-match preview highlighting, and mode refresh.

- [ ] **Step 2: Implement the session behind the existing facade**

Move the stream/task/actor/generation/index-range/corpus/apply helpers without
changing the facade's `searchQuery`, `refreshForModeChange`,
`waitForInFlightSearch`, or test-visible generation interface. Empty query calls
`publishVisible(all)` directly; delete the legacy `Search` dependency.

- [ ] **Step 3: Regenerate, verify static closures, and run GREEN**

```sh
rg -n "private let search = Search|Search\.SearchResult|all\.first\(where:.*dto\.id" Maccy
git diff --check
git add Maccy MaccyTests Maccy.xcodeproj/project.pbxproj
git commit -m "refactor(b2b): extract History search session"
git push origin b2-b5-history
gh workflow run "macOS 26 ARM CI" --ref b2-b5-history
```

Expected: no legacy engine/O(matches×n) resolution, full matrix green, C3 and
DS-010/012 closed. If corpus-lag tests disprove the accepted DS-029 behavior,
fix it in a separate red-green commit before continuing.

---

## Task 8: B2c complete the persistence seam and extract store projection

**Files:**
- Create: `Maccy/Observables/HistoryStoreProjector.swift`
- Create: `MaccyTests/HistoryStoreProjectorTests.swift`
- Modify: `Maccy/Observables/HistoryPersistence.swift`
- Modify: `Maccy/Observables/History.swift`
- Modify: `MaccyTests/IngestErrorPropagationTests.swift`
- Generated: `Maccy.xcodeproj/project.pbxproj`

**Interfaces:**
- Add only immediately consumed persistence operations:
  `model(for:) -> HistoryItem?` and the existing `fetchAll`; no generic repo.
- Projector interface: `load() throws`,
  `consume(_:trimmedPersistentIDs:)`, and `reconcile()`.
- It owns sorter/decorator construction, incremental insertion, trimmed-ID
  cleanup, full fallback, reuse, and corpus synchronization.

- [ ] **Step 1: Write RED projector tests through a real fake adapter**

Prove load fetch failure preserves the old list and reports the error through
the facade, model miss triggers fake-backed reconcile without touching
`Storage.shared`, `.merged` removes the actor-reported duplicate ID, and
reconcile reuses decorators by persistent identity.

- [ ] **Step 2: Extend the persistence interface minimally**

Implement `model(for:)` in `SwiftDataHistoryPersistence` and the test fake. Route
load/reconcile/model lookup through the injected adapter before moving code.
This is now a real two-adapter seam with immediate tests, not standalone DS-022.

- [ ] **Step 3: Extract projector implementation**

Move load/limit/consume/incremental/reconcile/remove-decorator helpers. Keep all
module and decorator access on `@MainActor`. Projector emits value UI effects
and calls search-session corpus operations; it never imports AppState.

- [ ] **Step 4: Verify zero direct Storage IO and run GREEN**

```sh
rg -n "Storage\.shared\.context" \
  Maccy/Observables/History.swift \
  Maccy/Observables/HistoryStoreProjector.swift
git diff --check
git add Maccy MaccyTests Maccy.xcodeproj/project.pbxproj
git commit -m "refactor(b2c): extract History store projector"
git push origin b2-b5-history
gh workflow run "macOS 26 ARM CI" --ref b2-b5-history
```

Expected: no direct context matches and full matrix green; DS-022 closes.

---

## Task 9: C4 batch load-limit deletes before mutation extraction

**Files:**
- Modify: `Maccy/Observables/HistoryPersistence.swift`
- Modify: `Maccy/Observables/HistoryStoreProjector.swift`
- Modify: `MaccyTests/HistoryStoreProjectorTests.swift`

**Interfaces:**
- Adds one persistence operation accepting the exact overflow models or stored
  IDs and deleting them in one transaction/save.
- Replaces per-item `delete()` calls in load-size trimming.

- [ ] **Step 1: Write RED transaction-count/overflow test**

Use a recording fake to assert one batch-delete call carries exactly the
unpinned overflow and pinned rows survive. Confirm RED because the current
projector invokes individual deletes.

- [ ] **Step 2: Implement one batch operation and run GREEN**

Do not fetch the table again and do not change sort/retention semantics.

```sh
git add Maccy MaccyTests
git commit -m "perf(c4): batch load-limit deletions"
git push origin b2-b5-history
gh workflow run "macOS 26 ARM CI" --ref b2-b5-history
```

Expected: full matrix green; DS-014 closed.

---

## Task 10: B2d extract user mutations

**Files:**
- Create: `Maccy/Observables/HistoryMutations.swift`
- Create: `MaccyTests/HistoryMutationsTests.swift`
- Modify: `Maccy/Observables/History.swift`
- Generated: `Maccy.xcodeproj/project.pbxproj`

**Interfaces:**
- Module methods: `clear`, `clearAll`, `delete`, `select`, `togglePin`.
- Dependencies are injected concrete closures/modules for clipboard copy/clear,
  ingest-index synchronization, UI effect sink, persistence, list state, search
  session, sorter, and logger. No dependency is created inside the module.

- [ ] **Step 1: Write RED mutation tests**

Use recording persistence/effect/clipboard/ingestor adapters to prove:

- failed clear/delete/pin leaves list and UI effects unchanged and records error;
- successful clear keeps pins and sends exact removed store IDs;
- clear-all cleans decorators and clears corpus/index;
- select maps modifier flags to copy/paste behavior and close effect;
- pin rollback restores the old pin on save failure and successful unpin emits
  scroll target.

- [ ] **Step 2: Extract one method family at a time**

Move clear/clearAll, then delete/cleanup/sync, then select, then togglePin. Keep
facade method names and signatures as thin stable commands. Run the unit shard
after each family commit; run the full matrix after the module is complete.

- [ ] **Step 3: Regenerate and verify coupling deletion**

```sh
rg -n "AppState\.shared|Storage\.shared\.context" \
  Maccy/Observables/History*.swift Maccy/Search/HistorySearchSession.swift
wc -l Maccy/Observables/History.swift Maccy/Observables/HistoryMutations.swift
git diff --check
```

Expected: no forbidden singleton/direct-context matches; no extracted module
approaches the old facade size.

- [ ] **Step 4: Commit and run full GREEN**

```sh
git add Maccy MaccyTests Maccy.xcodeproj/project.pbxproj
git commit -m "refactor(b2d): extract History mutations"
git push origin b2-b5-history
gh workflow run "macOS 26 ARM CI" --ref b2-b5-history
```

---

## Task 11: Finish the facade and B2–B5 audit

**Files:**
- Modify: `Maccy/Observables/History.swift`
- Modify: `docs/audit/2026-07-10-master-roadmap.md`
- Modify: `docs/audit/2026-07-10-history-split-plan/README.md`
- Modify: `docs/audit/2026-07-10-history-split-plan/07-forcing-gate-and-split-order.md`
- Modify: `docs/audit/2026-07-09-design-audit-verification/01-verdict-matrix.md`
- Modify: `docs/audit/2026-07-09-design-structure-audit/17-findings-catalog.md`
- Modify: `docs/audit/architecture-and-root-causes.md`
- Modify: `docs/audit/INDEX.md`

**Interfaces:**
- Final `History` owns composition, Defaults listeners, facade properties, and
  forwarding commands only. Modules own their state/implementation.

- [ ] **Step 1: Remove residual implementation from the facade**

Delete helpers now owned by modules, unused imports, duplicate state, DEBUG
failure seams replaced by fake persistence, and compatibility setters that no
test uses. Keep `HistoryRef.decorators()` and application-facing names.

- [ ] **Step 2: Run the structural completion audit**

```sh
rg -n "func add\(|sessionLog|MainActorIngestorAdapter|AppState\.shared|Storage\.shared\.context" \
  Maccy/Observables/History*.swift Maccy/Search/HistorySearchSession.swift MaccyTests
rg -n "invalidateInFlightSearch" Maccy
wc -l Maccy/Observables/History*.swift Maccy/Search/HistorySearchSession.swift
git diff --check
```

Expected: first search has no matches; invalidation is owned by the search
session/list-state chokepoint rather than scattered public mutations; facade and
each module have focused sizes.

- [ ] **Step 3: Run final code matrix before docs-only audit commit**

```sh
git add Maccy MaccyTests Maccy.xcodeproj/project.pbxproj
git commit -m "refactor(b2): finish cohesive History facade"
git push origin b2-b5-history
gh workflow run "macOS 26 ARM CI" --ref b2-b5-history
```

Expected: full generated-project matrix green.

- [ ] **Step 4: Record exact commit/run evidence without another CI**

Update the listed authority docs with actual LOC, commit hashes, run IDs, closed
finding IDs, and any measured deviation. Commit only documentation:

```sh
git add docs/audit
git commit -m "docs(b2-b5): record History decomposition evidence"
```

Do not trigger CI for this pure documentation commit. Fast-forward master only
after confirming it descends from the code head that passed the final matrix.

---

## Plan self-review

- **Spec coverage:** Tasks 1–4 close B3/B4; Task 6 closes B5 and establishes the
  list-state seam; Tasks 5–10 implement UI inversion and all B2 modules; Task 7
  folds C3/DS-010/012 into the justified search extraction; Task 9 closes C4;
  Task 11 audits all design goals.
- **No placeholders:** every task names exact files, interfaces, commands,
  expected failures/success, and commit boundaries.
- **Type consistency:** `HistoryListState` is the shared main-actor list module;
  `HistorySearchSession` owns generation/corpus; `HistoryStoreProjector` owns
  store projection; `HistoryMutations` owns commands; `HistoryUIEffectSink` is
  the only route from History modules to UI state.
