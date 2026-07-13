# Decorator Factory Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make decorator construction an explicit History-owned dependency, remove `HistoryItemDecorator`'s hidden process-wide image dependencies, and keep ingestion and UI decoration on one shared production image processor.

**Architecture:** Add a main-actor `HistoryItemDecoratorFactory` that owns the image processor and application-icon cache and is the only constructor used by `HistoryStoreProjector`. `History.shared` creates the live factory, while ordinary `History` instances get isolated resources. `CompositionRoot` obtains the ingest processor from its composed History, and memory reclamation delegates through that same History instead of reaching a cache singleton.

**Tech Stack:** Swift 6 complete concurrency, AppKit, Observation, SwiftData, XCTest, XcodeGen, GitHub Actions macOS arm64 runner.

## Global Constraints

- Do not run Xcode, tests, SwiftLint, or `xcodebuild` locally; this host has no macOS toolchain.
- Do not change startup fetch count, decorator count, image row geometry, decode target sizes, or decode timing.
- Production ingest and UI decoration must use the exact same `ImageProcessing` instance.
- Ordinary tests must not inherit a process-wide image processor or application-image cache.
- Commit every RED and implementation step locally; push the complete compile boundary once for the full CI matrix.
- Do not touch the user's dirty files in the primary worktree.

---

### Task 1: Define the cohesive decorator factory

**Files:**
- Create: `Maccy/Observables/HistoryItemDecoratorFactory.swift`
- Modify: `Maccy/Observables/HistoryItemDecorator.swift`
- Modify: `Maccy/ApplicationImageCache.swift`
- Test: `MaccyTests/HistoryStoreProjectorTests.swift`
- Test: `MaccyTests/ApplicationImageCacheTests.swift`

**Interfaces:**
- Consumes: `ImageProcessing`, `ApplicationImageCache.getImage(item:)`, and `HistoryItemDecorator.init`.
- Produces: `HistoryItemDecoratorFactory.make(_:)`, `imageProcessor`, and `purgeApplicationImages()`.

- [x] **Step 1: Write the failing factory ownership test**

Add a test-local application-image provider that records each model passed through the factory, then assert the made decorator receives the provider's exact object:

```swift
func testDecoratorFactoryOwnsApplicationImageResolution() {
  let item = item(title: "factory")
  let expected = ApplicationImage(bundleIdentifier: nil)
  var resolved: [HistoryItem] = []
  let factory = HistoryItemDecoratorFactory(
    imageProcessor: PassthroughImageProcessor(),
    applicationImage: {
      resolved.append($0)
      return expected
    },
    purgeApplicationImages: {}
  )

  let decorated = factory.make(item)

  XCTAssertEqual(resolved.count, 1)
  XCTAssertTrue(resolved[0] === item)
  XCTAssertTrue(decorated.applicationImage === expected)
}
```

Change each `ApplicationImageCacheTests` case from `ApplicationImageCache.shared` to a fresh `ApplicationImageCache()` so the tests lock instance isolation.

- [x] **Step 2: Record the RED boundary**

Do not run locally. The expected runner failure is a compile error because `HistoryItemDecoratorFactory` and the explicit `applicationImage` initializer input do not exist. Commit the tests:

```bash
git add MaccyTests/HistoryStoreProjectorTests.swift MaccyTests/ApplicationImageCacheTests.swift
git commit -m "test(quality): define decorator image ownership"
```

- [x] **Step 3: Implement the minimal factory and explicit decorator input**

Create a main-actor value that owns only construction resources:

```swift
@MainActor
struct HistoryItemDecoratorFactory {
  let imageProcessor: any ImageProcessing
  private let applicationImage: @MainActor (HistoryItem) -> ApplicationImage
  private let purgeApplicationImagesAction: @MainActor () -> Void

  init(
    imageProcessor: any ImageProcessing,
    applicationImage: @escaping @MainActor (HistoryItem) -> ApplicationImage,
    purgeApplicationImages: @escaping @MainActor () -> Void
  ) {
    self.imageProcessor = imageProcessor
    self.applicationImage = applicationImage
    self.purgeApplicationImagesAction = purgeApplicationImages
  }

  init(imageProcessor: any ImageProcessing, applicationImages: ApplicationImageCache) {
    self.init(
      imageProcessor: imageProcessor,
      applicationImage: { applicationImages.getImage(item: $0) },
      purgeApplicationImages: { applicationImages.purge() }
    )
  }

  func make(_ item: HistoryItem, shortcuts: [KeyShortcut] = []) -> HistoryItemDecorator {
    HistoryItemDecorator(
      item,
      shortcuts: shortcuts,
      imageProcessor: imageProcessor,
      applicationImage: applicationImage(item)
    )
  }

  func purgeApplicationImages() {
    purgeApplicationImagesAction()
  }
}
```

Add `live()` and `isolated()` factory methods. `live()` creates `ImageProcessor(cache: ThumbnailCache())`; `isolated()` uses `PassthroughImageProcessor()`. Each creates its own `ApplicationImageCache`. Make that cache `final`, remove its `.shared`, and change `HistoryItemDecorator.init` to accept `applicationImage: ApplicationImage? = nil`; use a nil-bundle fallback only for standalone test construction. Keep `PassthroughImageProcessor()` as the standalone decorator default until Task 2 removes every production use of that default.

- [x] **Step 4: Review and commit the factory**

Run read-only checks:

```bash
git diff --check
rg -n "ApplicationImageCache\.shared" MaccyTests/ApplicationImageCacheTests.swift
```

The search must return no matches. Commit:

```bash
git add Maccy/Observables/HistoryItemDecoratorFactory.swift Maccy/Observables/HistoryItemDecorator.swift Maccy/ApplicationImageCache.swift MaccyTests/ApplicationImageCacheTests.swift
git commit -m "refactor(quality): own decorator image resources"
```

---

### Task 2: Route every persisted projection through the factory

**Files:**
- Modify: `Maccy/Observables/HistoryStoreProjector.swift`
- Modify: `Maccy/Observables/History.swift`
- Modify: `Maccy/Observables/HistoryItemDecorator.swift`
- Test: `MaccyTests/HistoryStoreProjectorTests.swift`
- Test: `MaccyTests/HistoryDecoratorTests.swift`

**Interfaces:**
- Consumes: `HistoryItemDecoratorFactory.make(_:)` from Task 1.
- Produces: `History.init(... decoratorFactory:)`, `History.decoratorImageProcessor`, and one construction route for load, reconcile, and incremental insert.

- [x] **Step 1: Write the failing three-path projection test**

Construct a factory whose application-image closure appends model titles. Load one item, incrementally add a second, then reconcile a third while the first two decorators are reused:

```swift
func testInjectedFactoryBuildsEveryNewStoreProjection() async throws {
  let persistence = RecordingProjectorPersistence()
  let first = item(title: "load")
  persistence.fetchedItems = [first]
  var decoratedTitles: [String] = []
  let factory = HistoryItemDecoratorFactory(
    imageProcessor: PassthroughImageProcessor(),
    applicationImage: {
      decoratedTitles.append($0.title)
      return ApplicationImage(bundleIdentifier: nil)
    },
    purgeApplicationImages: {}
  )
  let history = History(
    persistence: persistence,
    decoratorFactory: factory,
    logsPersistenceErrors: false
  )

  try await history.load()
  let second = item(title: "incremental")
  persistence.models[second.persistentModelID] = second
  history.consume(.added(snapshot(of: second)))
  let third = item(title: "reconcile")
  persistence.fetchedItems = [first, second, third]
  history.consume(.cleared)

  XCTAssertEqual(decoratedTitles, ["load", "incremental", "reconcile"])
}
```

- [x] **Step 2: Commit the RED projection test**

The expected runner failure is `extra argument 'decoratorFactory' in call`. Commit:

```bash
git add MaccyTests/HistoryStoreProjectorTests.swift
git commit -m "test(quality): require one decorator construction route"
```

- [x] **Step 3: Inject and use the factory**

Add `decoratorFactory` to `HistoryStoreProjector.init` and replace all three bare constructor sites with `decoratorFactory.make(model)`. Add a factory parameter to `History.init` with `.isolated()` as its default, retain it, and pass it to the projector. In `History.makeShared`, create exactly one `.live()` factory and pass it to `History`. Expose only this internal read for the application composition boundary:

```swift
var decoratorImageProcessor: any ImageProcessing {
  decoratorFactory.imageProcessor
}
```

Remove `HistoryItemDecorator.defaultImageProcessor`; change the one test helper that references it to `PassthroughImageProcessor()`.

- [x] **Step 4: Prove there are no production bypasses and commit**

```bash
rg -n "HistoryItemDecorator\(" Maccy/Observables/HistoryStoreProjector.swift
rg -n "defaultImageProcessor" Maccy/Observables MaccyTests
git diff --check
```

Both searches must return no matches. `CompositionRoot` retains the final live
default until Task 3 replaces it with the composed History processor. Commit:

```bash
git add Maccy/Observables/HistoryStoreProjector.swift Maccy/Observables/History.swift Maccy/Observables/HistoryItemDecorator.swift MaccyTests/HistoryStoreProjectorTests.swift MaccyTests/HistoryDecoratorTests.swift
git commit -m "refactor(quality): centralize decorator construction"
```

---

### Task 3: Reuse and reclaim the composed image resources

**Files:**
- Modify: `Maccy/Application/CompositionRoot.swift`
- Modify: `Maccy/Observables/MemoryGovernance.swift`
- Modify: `Maccy/Observables/History.swift`
- Test: `MaccyTests/MemoryGovernanceTests.swift`

**Interfaces:**
- Consumes: `History.decoratorImageProcessor` and `HistoryItemDecoratorFactory.purgeApplicationImages()`.
- Produces: one shared production processor for ingest and decoration, and memory-pressure cleanup through the composed History.

- [x] **Step 1: Write the failing memory ownership test**

Add a `HistoryRef` fake that returns no decorators and records application-image purges:

```swift
func testMemoryWarningPurgesImagesOwnedByAttachedHistory() {
  let history = RecordingHistoryRef()
  let governor = MemoryGovernor()
  governor.attach(history: history)

  governor.handleMemoryWarning()

  XCTAssertEqual(history.applicationImagePurgeCount, 1)
}
```

The fake implements `decorators()` and the new `purgeApplicationImages()` protocol requirement. The RED failure is that the protocol and governor do not yet have this route.

- [x] **Step 2: Commit the RED memory test**

```bash
git add MaccyTests/MemoryGovernanceTests.swift
git commit -m "test(quality): define composed image reclamation"
```

- [x] **Step 3: Complete the composition**

Add `purgeApplicationImages()` to `HistoryRef`, delegate it from the `History` conformance to its factory, and replace `ApplicationImageCache.shared.purge()` in `MemoryGovernor` with `history?.purgeApplicationImages()`.

Change `CompositionRoot.init` to accept an optional explicit processor and otherwise take the processor from its composed History:

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
}
```

This preserves explicit processor injection while ensuring the default ingest and decorator paths share object identity.

- [x] **Step 4: Static verification and commit**

```bash
rg -n "ApplicationImageCache\.shared|defaultImageProcessor" Maccy MaccyTests
rg -n "HistoryItemDecorator\(" Maccy/Observables/HistoryStoreProjector.swift
git diff --check
```

All searches must return no matches. Commit:

```bash
git add Maccy/Application/CompositionRoot.swift Maccy/Observables/MemoryGovernance.swift Maccy/Observables/History.swift MaccyTests/MemoryGovernanceTests.swift
git commit -m "refactor(quality): compose decorator image lifetime"
```

- [ ] **Step 5: Regenerate the tracked Xcode project through the runner**

Push the branch without dispatching normal CI, then run `Regenerate and Validate
Xcode Project` once. Its validation job must generate twice, pass repeatability,
test-plan, parity, clean build, and bundle gates, and fail only the expected
committed-output drift gate. Download `xcodeproj-generated-<run-id>-1`, compare
it with the checkout, and mechanically copy the changed generated files; never
hand-edit `project.pbxproj`. Confirm both new Swift filenames occur in the
generated project and commit:

```bash
git add Maccy.xcodeproj Maccy.xctestplan
git commit -m "chore(project): regenerate for decorator factory files"
```

- [ ] **Step 6: Push one complete verification boundary**

Do not build locally. Push the generated-output commit and dispatch `macOS 26
ARM CI` once. Require XcodeGen zero drift, strict lint/build, unit, UI, and
performance shards. Poll at 90-second intervals. Diagnose any failure by job
first and tail of the failed job log; do not rerun a concrete
assertion/compiler failure as a flake.
