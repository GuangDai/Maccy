# Store-event Boundary Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serialize store-event synchronization with clipboard ingestion, remove the Clipboard-to-History singleton edge, and make clear-all pending-aware without destabilizing SwiftData model identifiers.

**Architecture:** Generalize the existing main-actor `IngestMailbox` into one FIFO for ingest and synchronization operations. Keep `Clipboard` as the narrow adapter, with failures leaving it through a composition-injected sink. Keep the model relationship as the authoritative child-cleanup owner; fetch parents with pending changes included and delete registered models individually instead of predicate-deleting or pre-saving temporary identifiers.

**Tech Stack:** Swift 6 complete concurrency, AppKit, SwiftData, XCTest, XcodeGen, GitHub Actions macOS arm64 runner.

## Global Constraints

- Do not run Xcode, tests, SwiftLint, or `xcodebuild` locally; this host has no macOS toolchain.
- Preserve every observed clipboard request and every committed store event in submission order.
- Only Sendable DTO values may cross the ingest actor boundary; no SwiftData model may cross.
- Do not add database I/O to each dedup candidate or change user-visible behavior.
- Commit each RED test step before its production implementation, but push the completed batch once for the full CI matrix.
- Do not touch the user's dirty files in the primary worktree.

---

### Task 1: One FIFO for ingests and store events

**Files:**
- Modify: `Maccy/Ingest/IngestMailbox.swift`
- Test: `MaccyTests/ClipboardTests.swift`

**Interfaces:**
- Consumes: `ClipboardIngestor.ingest(_:)` and `ClipboardIngestor.synchronizeStoreEvents(_:)`.
- Produces: `IngestMailbox.submit(storeEvents:to:)` alongside the existing request submission method.

- [x] **Step 1: Write the failing mixed-operation FIFO test**

Extend `BlockingIngestor` with an ordered string log and a store-event implementation, then add a test that blocks the first ingest, queues a clear event and second ingest, releases the first call, and asserts exact order:

```swift
func testIngestMailboxSerializesStoreEventsWithRequests() async {
  let blocking = BlockingIngestor()
  let mailbox = IngestMailbox()

  mailbox.submit(request(changeCount: 1), to: blocking) { _ in }
  await waitForBlockingIngestor(blocking, expectedOperationCount: 1)
  mailbox.submit(storeEvents: [.cleared], to: blocking)
  mailbox.submit(request(changeCount: 2), to: blocking) { _ in }

  await blocking.releaseFirstRequest()
  await waitForBlockingIngestor(blocking, expectedOperationCount: 3)

  XCTAssertEqual(await blocking.operations, ["ingest:1", "events:cleared", "ingest:2"])
}
```

The actor records `request.source.changeCount` for ingests and a stable label for the `.cleared` event. Rename the polling helper parameter from `expectedRequestCount` to `expectedOperationCount` and read the actor's operation count.

- [x] **Step 2: Record the RED test boundary**

Do not run locally. The expected runner failure is a compile error because `IngestMailbox` has no `submit(storeEvents:to:)` overload. Commit only the test change:

```bash
git add MaccyTests/ClipboardTests.swift
git commit -m "test(quality): define mixed store event mailbox order"
```

- [x] **Step 3: Implement the minimal generalized mailbox**

Replace the request-only entry with a private operation enum:

```swift
private enum Operation {
  case ingest(
    request: IngestRequest,
    ingestor: any ClipboardIngestor,
    completion: @MainActor (IngestResult) -> Void
  )
  case synchronize(events: [StoreEvent], ingestor: any ClipboardIngestor)
}
```

Store `[Operation]`, append `.ingest` in the existing `submit`, and add:

```swift
func submit(storeEvents: [StoreEvent], to ingestor: any ClipboardIngestor) {
  guard !storeEvents.isEmpty else { return }
  operations.append(.synchronize(events: storeEvents, ingestor: ingestor))
  startDrainIfNeeded()
}
```

Extract the shared `drainTask == nil` check into `startDrainIfNeeded()`. In `drain()`, switch on each operation and await either `ingest` plus completion or `synchronizeStoreEvents`. Retain index-based draining and capacity reuse.

- [x] **Step 4: Review concurrency invariants and commit**

Confirm the mailbox remains `@MainActor`, only one drain task can exist, and no detached task was added. Run `git diff --check`, then commit:

```bash
git add Maccy/Ingest/IngestMailbox.swift
git commit -m "fix(quality): serialize store events with clipboard ingest"
```

---

### Task 2: Clipboard adapter and composition-owned failure sink

**Files:**
- Modify: `Maccy/Clipboard.swift`
- Modify: `Maccy/Observables/History.swift`
- Modify: `Maccy/Application/CompositionRoot.swift`
- Test: `MaccyTests/ClipboardTests.swift`

**Interfaces:**
- Consumes: `IngestMailbox.submit(storeEvents:to:)` from Task 1.
- Produces: `Clipboard.synchronizeStoreEvents(_:)`, `Clipboard.configureIngestFailureSink(_:)`, and an initializer-injected inert failure sink.

- [x] **Step 1: Write failing adapter and failure-sink tests**

Add an async adapter test using the existing `IngestorSpy`:

```swift
func testStoreEventsUseClipboardMailboxAdapter() async {
  let spy = IngestorSpy()
  clipboard.ingestor = spy

  clipboard.synchronizeStoreEvents([.cleared])
  await waitForStoreEventBatches(spy, expectedCount: 1)

  XCTAssertEqual(await spy.storeEventBatches, [[.cleared]])
}
```

Replace the singleton-coupled failure assertion with a local Clipboard and captured errors:

```swift
func testSurfaceIngestFailureInvokesConfiguredSinkForPersistenceFailureOnly() {
  var errors: [Error] = []
  let subject = Clipboard(ingestFailureSink: { errors.append($0) })

  subject.surfaceIngestFailureIfNeeded(
    IngestResult(event: nil, metrics: .zero, persistenceFailed: true)
  )
  subject.surfaceIngestFailureIfNeeded(IngestResult(event: nil, metrics: .zero))

  XCTAssertEqual(errors.count, 1)
}
```

Add a polling helper that reads `spy.storeEventBatches.count`. These tests intentionally fail to compile until the new Clipboard APIs exist.

- [x] **Step 2: Commit the RED tests**

```bash
git add MaccyTests/ClipboardTests.swift
git commit -m "test(quality): define clipboard boundary outputs"
```

- [x] **Step 3: Add the Clipboard APIs**

Add an inert-by-default sink stored on the main-actor class:

```swift
private var ingestFailureSink: @MainActor (Error) -> Void

init(
  ingestFailureSink: @escaping @MainActor (Error) -> Void = { _ in }
) {
  changeCount = pasteboard.changeCount
  self.ingestFailureSink = ingestFailureSink
}

func configureIngestFailureSink(
  _ sink: @escaping @MainActor (Error) -> Void
) {
  ingestFailureSink = sink
}
```

Add the store-event adapter:

```swift
func synchronizeStoreEvents(_ events: [StoreEvent]) {
  guard !events.isEmpty, let ingestor else { return }
  ingestMailbox.submit(storeEvents: events, to: ingestor)
}
```

Change `surfaceIngestFailureIfNeeded` to call `ingestFailureSink(ClipboardIngestPersistenceError())`; remove its `History.shared` access.

- [x] **Step 4: Replace live fire-and-forget wiring**

In `History.makeShared`, replace the unstructured task closure with:

```swift
publishStoreEvents: { Clipboard.shared.synchronizeStoreEvents($0) }
```

In `CompositionRoot.prepareForLaunch`, before starting the clipboard, wire the composed instance:

```swift
clipboard.configureIngestFailureSink { [weak history] error in
  history?.lastPersistError = error
}
```

Use the existing local `history = appState.history`; do not fetch either singleton in this closure.

- [x] **Step 5: Verify the dependency direction and commit**

Run read-only checks:

```bash
rg -n "History\.shared" Maccy/Clipboard.swift
rg -n "Task \{ await ingestor\.synchronizeStoreEvents" Maccy
git diff --check
```

Both searches must return no matches. Commit:

```bash
git add Maccy/Clipboard.swift Maccy/Observables/History.swift Maccy/Application/CompositionRoot.swift
git commit -m "refactor(quality): compose clipboard history outputs"
```

---

### Task 3: Pending-aware clear-all cascade semantics

**Files:**
- Modify: `Maccy/Observables/HistoryPersistence.swift`
- Test: `MaccyTests/HistoryPinPersistenceTests.swift`

**Interfaces:**
- Consumes: existing `HistoryPersistence.deleteAll()` throwing contract.
- Produces: complete saved-plus-pending deletion with model-owned child cascading.

- [x] **Step 1: Write a SQLite cascade regression test**

Create a temporary disk-backed `Storage`, insert and save one item with content,
run the existing `deleteAll()`, then assert both entity counts are zero:

```swift
func testDeleteAllRemovesSavedContentsFromSQLiteStore() throws {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: UUID().uuidString, directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let storage = Storage(
    url: directory.appending(path: "Storage.sqlite"),
    storedInMemoryForTesting: false,
    onCorruption: { _ in }
  )
  storage.context.insert(historyItem("saved-clear-all"))
  try storage.context.save()

  try SwiftDataHistoryPersistence(context: storage.context).deleteAll()

  XCTAssertEqual(try storage.context.fetchCount(FetchDescriptor<HistoryItem>()), 0)
  XCTAssertEqual(try storage.context.fetchCount(FetchDescriptor<HistoryItemContent>()), 0)
}
```

This verifies Apple's SwiftData `.cascade` relationship contract for saved rows.

- [x] **Step 2: Add a RED saved-plus-pending regression test**

Use an isolated in-memory storage. Save one row, insert a second row without
saving, call `deleteAll()`, and assert both model counts are zero. The old
predicate delete leaves the pending row behind.

- [x] **Step 3: Fetch pending parents and delete registered models**

Build a `FetchDescriptor<HistoryItem>` with `includePendingChanges = true`,
fetch once, and delegate to the existing per-model batch delete implementation.
Do not pre-save temporary identifiers and do not explicitly delete children.

- [x] **Step 4: Commit the persistence fix**

```bash
git add Maccy/Observables/HistoryPersistence.swift \
  MaccyTests/HistoryPinPersistenceTests.swift
git commit -m "fix(quality): clear registered history models"
```

CI evidence leading to this design: predicate deletion left parent/content
counts nonzero (for example 46/56 → 11/13), while fetching pending parents and
deleting registered models reduced both counts to zero without remapping
temporary identifiers. Child deletion remains the relationship's job.

- [x] **Step 5: Add a RED Defaults-resort regression test**

Create a fake-backed `History` with a complete projection whose first-copy and
last-copy orders differ. Change `.sortBy`, then assert the same decorators are
reordered and `fetchAll()` is never called.

- [x] **Step 6: Resort the owned projection without store IO**

Add `HistoryStoreProjector.resort()` and route the `.sortBy` / `.pinTo`
watchers through it. CI showed that the former post-clear reconcile could trap
inside SwiftData on the first `HistoryConsumeTests` case; the preferences change
only ordering, so fetching persistence was both unnecessary and the wrong
boundary.

---

### Task 4: Batch verification and integration

**Files:**
- Verify: all files changed in Tasks 1-3
- Verify: generated `Maccy.xcodeproj/project.pbxproj` remains reproducible

**Interfaces:**
- Consumes: completed commits from Tasks 1-3.
- Produces: one CI-green branch ready for fast-forward integration.

- [x] **Step 1: Perform static review before push**

Run only host-safe checks:

```bash
git diff --check master...HEAD
git status --short
rg -n "History\.shared" Maccy/Clipboard.swift
rg -n "Task \{ await ingestor\.synchronizeStoreEvents" Maccy
git log --oneline master..HEAD
```

Expected: clean whitespace, only intentional files, no forbidden dependency/task matches, and separate test/implementation commits.

- [ ] **Step 2: Push once and use the existing automatic/manual workflow once**

```bash
git push -u origin quality-store-event-boundary
gh workflow run "macOS 26 ARM CI" --ref quality-store-event-boundary
```

Poll no more often than every 90 seconds. Inspect job conclusions before logs if the matrix fails; tail only the failed job log.

- [ ] **Step 3: Review and integrate only after full green**

Require success for generated project, lint/build, unit, UI shards, and performance shards. Then fast-forward local `master`, preserve the user's dirty primary-worktree files, push `master`, and monitor its automatic CI at the same cadence.
