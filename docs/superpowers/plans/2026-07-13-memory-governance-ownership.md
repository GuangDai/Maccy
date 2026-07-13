# Memory Governance Ownership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove `MemoryGovernor.shared` and `VisibilityTracker.shared` by giving every AppState/CompositionRoot graph one explicit memory-governance identity.

**Architecture:** `AppState` owns the viewport tracker already consumed by its row views. `CompositionRoot` owns a governor initialized with that exact tracker; the governor weakly captures itself in the dispatch callback and applies the unchanged release policy to its attached History.

**Tech Stack:** Swift 6.0 complete strict concurrency, SwiftUI Observation/AppState environment, AppKit dispatch memory pressure, XCTest, GitHub Actions macOS 26 ARM runner.

## Global Constraints

- Target macOS Sonoma 14+ and preserve Swift 6 complete strict-concurrency compliance.
- Do not build, test, or lint locally; this machine has no Xcode/macOS toolchain.
- Preserve image height, preview geometry, decode policy, cache budgets, memory-warning release policy, and launch timing.
- Keep the dispatch source on `.main`; do not add `@unchecked Sendable` or unsafe isolation escapes.
- Do not add a protocol, adapter, custom SwiftUI environment key, or new production/test Swift file.
- Commit the design, implementation, and evidence as separate coherent commits; run one full CI matrix for the code SHA.
- Poll CI every 90 seconds per the user's explicit instruction.
- Do not edit the primary worktree's dirty files, including `docs/audit/INDEX.md`.

---

### Task 1: Lock instance-owned viewport policy and remove both globals

**Files:**
- Modify: `MaccyTests/MemoryGovernanceTests.swift`
- Modify: `Maccy/Observables/AppState.swift:25-75`
- Modify: `Maccy/Observables/MemoryGovernance.swift:40-116`
- Modify: `Maccy/Application/CompositionRoot.swift:6-72`
- Modify: `Maccy/Views/HistoryItemView.swift:55-63`

**Interfaces:**
- Consumes: existing `MemoryGovernanceHistory`, `VisibilityObserving`, `HistoryItemDecorator.releaseTransientImages`, and the owning `AppState` SwiftUI environment.
- Produces:
  - `AppState.visibilityTracker: VisibilityTracker`
  - `AppState.init(history:footer:runtimeServices:visibilityTracker:)`
  - `MemoryGovernor.init(visibilityTracker:)`
  - `CompositionRoot.memoryGovernor: MemoryGovernor` as a read-only internal regression seam

- [ ] **Step 1: Add the source-level RED policy and ownership tests**

Replace the single broad test in `MaccyTests/MemoryGovernanceTests.swift` with two focused tests and a narrow spy:

```swift
import AppKit
import XCTest
@testable import Maccy

@MainActor
final class MemoryGovernanceTests: XCTestCase {
  func testCompositionRootMemoryWarningKeepsVisibleImagesAndReleasesHiddenImages() {
    let visible = decorator("visible")
    let hidden = decorator("hidden")
    visible.previewImage = NSImage(size: NSSize(width: 2, height: 2))
    visible.thumbnailImage = NSImage(size: NSSize(width: 2, height: 2))
    hidden.previewImage = NSImage(size: NSSize(width: 2, height: 2))
    hidden.thumbnailImage = NSImage(size: NSSize(width: 2, height: 2))
    let tracker = VisibilityTracker()
    tracker.register(visible)
    let appState = appState(visibilityTracker: tracker)
    let root = CompositionRoot(appState: appState)
    let history = MemoryHistorySpy(decorators: [visible, hidden])
    root.memoryGovernor.attach(history: history)

    root.memoryGovernor.handleMemoryWarning()

    XCTAssertNotNil(visible.previewImage)
    XCTAssertNotNil(visible.thumbnailImage)
    XCTAssertNil(hidden.previewImage)
    XCTAssertNil(hidden.thumbnailImage)
    XCTAssertEqual(history.purgeApplicationImagesCalls, 1)
  }

  func testAppStatesUseTheirInjectedVisibilityTracker() {
    let firstTracker = VisibilityTracker()
    let secondTracker = VisibilityTracker()
    let observer = decorator("observer")
    let first = appState(visibilityTracker: firstTracker)
    let second = appState(visibilityTracker: secondTracker)

    first.visibilityTracker.register(observer)

    XCTAssertTrue(first.visibilityTracker === firstTracker)
    XCTAssertTrue(second.visibilityTracker === secondTracker)
    XCTAssertTrue(first.visibilityTracker.isVisible(observer.id))
    XCTAssertFalse(second.visibilityTracker.isVisible(observer.id))
  }

  private func decorator(_ title: String) -> HistoryItemDecorator {
    HistoryItemDecorator(HistoryBuilder().withTitle(title).build())
  }

  private func appState(visibilityTracker: VisibilityTracker) -> AppState {
    let storage = Storage(storedInMemoryForTesting: true)
    let history = History(
      persistence: SwiftDataHistoryPersistence(context: storage.context),
      logsPersistenceErrors: false
    )
    return AppState(
      history: history,
      footer: Footer(),
      visibilityTracker: visibilityTracker
    )
  }
}

@MainActor
private final class MemoryHistorySpy: MemoryGovernanceHistory {
  private let values: [HistoryItemDecorator]
  private(set) var purgeApplicationImagesCalls = 0

  init(decorators: [HistoryItemDecorator]) {
    values = decorators
  }

  func decorators() -> [HistoryItemDecorator] { values }

  func purgeApplicationImages() {
    purgeApplicationImagesCalls += 1
  }
}
```

These tests are source-level RED before the implementation because neither
`AppState.visibilityTracker` nor `MemoryGovernor.init(visibilityTracker:)`
exists. Do not launch a separate knowingly-red workflow; this repository has no
local toolchain and the user requires CI batching. Continue immediately to the
minimal implementation in the same compile gate.

- [ ] **Step 2: Make AppState own the tracker**

Add the instance resource near `runtimeServices`:

```swift
@ObservationIgnored let visibilityTracker: VisibilityTracker
```

Extend the initializer without changing existing call sites:

```swift
init(
  history: History,
  footer: Footer,
  runtimeServices: AppStateRuntimeServices = .inert,
  visibilityTracker: VisibilityTracker = VisibilityTracker()
) {
  self.history = history
  self.footer = footer
  self.runtimeServices = runtimeServices
  self.visibilityTracker = visibilityTracker
  // existing popup/preview/navigation composition remains byte-for-byte
}
```

- [ ] **Step 3: Inject tracker into MemoryGovernor and capture its instance**

In `MemoryGovernance.swift`, delete both `static let shared` declarations. Give
the governor a required tracker:

```swift
@MainActor
final class MemoryGovernor {
  private weak var history: MemoryGovernanceHistory?
  private let visibilityTracker: VisibilityTracker
  private var memoryPressureSource: DispatchSourceMemoryPressure?

  init(visibilityTracker: VisibilityTracker) {
    self.visibilityTracker = visibilityTracker
  }
```

Keep the source on `.main`, but replace its global re-entry:

```swift
source.setEventHandler { [weak self] in
  self?.handleMemoryWarning()
}
```

Read the injected tracker in the unchanged release policy:

```swift
let visibleIDs = visibilityTracker.snapshot()
```

Update the isolation comment to describe the weak instance capture; do not
retain the old `MemoryGovernor.shared`/`MainActor.assumeIsolated` explanation.

- [ ] **Step 4: Make CompositionRoot own the matching governor**

Add a read-only internal property; matching the existing `imageProcessor`
regression seam keeps the production identity structural while allowing
`@testable` coverage:

```swift
/// Governor constructed from the composed AppState's visibility tracker.
/// Internal so the composition-identity contract can be regression tested.
let memoryGovernor: MemoryGovernor
```

Construct it unconditionally from the AppState tracker; do not accept a
preconstructed governor because it could carry a different tracker:

```swift
init(
  appState: AppState = .shared,
  clipboard: Clipboard = .shared,
  storage: Storage = .shared,
  imageProcessor: (any ImageProcessing)? = nil
) {
  self.appState = appState
  self.clipboard = clipboard
  self.storage = storage
  self.imageProcessor = imageProcessor ?? appState.history.decoratorImageProcessor
  self.memoryGovernor = MemoryGovernor(visibilityTracker: appState.visibilityTracker)
}
```

Remove the method-level default from `finishLaunching` and use the stored value:

```swift
func finishLaunching(panel: NSWindow) {
  appState.preview.attach(window: panel)
  memoryGovernor.attach(history: appState.history)
  memoryGovernor.start()
}
```

- [ ] **Step 5: Route viewport events through the owning AppState**

In `HistoryItemView`, preserve callback order and replace only the identity:

```swift
.onAppear {
  appState.visibilityTracker.register(item)
  item.onAppearInViewport()
}
.onDisappear {
  item.onDisappearFromViewport()
  appState.visibilityTracker.unregister(item)
}
```

- [ ] **Step 6: Perform static verification**

Run:

```bash
git diff --check
test -z "$(rg -n 'MemoryGovernor\.shared|VisibilityTracker\.shared' Maccy --glob '*.swift')"
rg -n "visibilityTracker|memoryGovernor" \
  Maccy/Observables/AppState.swift \
  Maccy/Observables/MemoryGovernance.swift \
  Maccy/Application/CompositionRoot.swift \
  Maccy/Views/HistoryItemView.swift
```

Expected: no diff errors; zero production shared references; exactly one tracker
flows from each AppState through its views and root-owned governor.

- [ ] **Step 7: Commit the compile gate**

```bash
git add MaccyTests/MemoryGovernanceTests.swift \
  Maccy/Observables/AppState.swift \
  Maccy/Observables/MemoryGovernance.swift \
  Maccy/Application/CompositionRoot.swift \
  Maccy/Views/HistoryItemView.swift
git commit -m "refactor(quality): own memory governance per composition"
```

---

### Task 2: Review, record, verify, and integrate

**Files:**
- Modify: `docs/audit/architecture-and-root-causes.md`

**Interfaces:**
- Consumes: the Task 1 ownership graph.
- Produces: authoritative architecture status and full runner evidence.

- [ ] **Step 1: Run an independent read-only review of the Task 1 commit**

Check strict-concurrency closure isolation, object lifetime, injected identity,
viewport callback order, release behavior, and the absence of UI/layout/startup
changes. Fix every Critical/Important finding before CI.

- [ ] **Step 2: Add a pending architecture entry**

Record that AppState owns viewport membership, CompositionRoot owns the matching
MemoryGovernor, and production has zero `MemoryGovernor.shared` /
`VisibilityTracker.shared` references. Mark the full matrix pending and commit:

```bash
git add docs/audit/architecture-and-root-causes.md
git commit -m "docs(quality): record memory governance ownership"
```

- [ ] **Step 3: Push and run one full CI matrix when no workflow is active**

```bash
git push -u origin quality-memory-governance-ownership
gh workflow run "macOS 26 ARM CI" --ref quality-memory-governance-ownership
```

Poll every 90 seconds. Required success jobs: Generated Xcode project, Lint +
diagnostics, unit, ui-1, ui-2, perf-text, and perf-image. There are no new Swift
files, so no project-generation workflow is required.

- [ ] **Step 4: Record exact evidence and fast-forward master**

Replace the pending marker with the green run ID, commit the docs-only evidence
without another CI batch, and fast-forward `master` only if the primary dirty
file list is identical before and after.

## Self-Review

- Spec coverage: ownership, identity, lifecycle, release behavior, and explicit
  non-goals each map to a concrete implementation or test step.
- Placeholder scan: no TBD/TODO, generic error-handling request, or undefined
  neighboring interface remains.
- Type consistency: `AppState.visibilityTracker`,
  `MemoryGovernor.init(visibilityTracker:)`, and
  `CompositionRoot.memoryGovernor` match in every task and test; the root has no
  alternate governor injection path that could violate tracker identity.
- Scope: five existing Swift files plus one existing test file; no generated
  project change or UI/layout behavior change.
