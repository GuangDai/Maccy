# Image Generation Coordinator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract per-row image loading, generation, cancellation, publication, and release from `HistoryItemDecorator` into one cohesive coordinator without changing UI behavior.

**Architecture:** `HistoryItemDecorator` privately composes a main-actor `ImageGenerationCoordinator` and keeps its current public image facade. The coordinator lazily obtains bytes through an injected main-actor closure and runs thumbnail/preview through one kind-parameterized pipeline.

**Tech Stack:** Swift 6 strict concurrency, Observation, AppKit, `ImageProcessing`, XCTest, XcodeGen, GitHub Actions.

## Global Constraints

- Keep main-window image-row height independent of source-image dimensions.
- Preserve the current preview/thumbnail caps, cache-release behavior, and startup laziness.
- Do not expose the coordinator to SwiftUI views or add new process-wide shared state.
- Use TDD: failing runner evidence before production code.
- Do not run Xcode, Swift tests, or SwiftLint locally.
- Run only one GitHub workflow at a time and sleep 90 seconds before every status recheck.

---

### Task 1: RED coordinator lifecycle contract

**Files:**
- Modify temporarily: `MaccyTests/HistoryDecoratorTests.swift`

**Interfaces:**
- Consumes: planned `ImageGenerationCoordinator(imageProcessor:imageData:)`.
- Produces: tests for lazy byte loading, release/reload, scroll-out policy, and invalidation.

- [ ] **Step 1: Add failing coordinator-focused tests to the already registered test file**

```swift
@MainActor
final class ImageGenerationCoordinatorTests: XCTestCase {
  func testLoadsBytesLazilyAndReloadsAfterMemoryRelease() async throws {
    var loads = 0
    let data = try XCTUnwrap(NSImage(named: "StatusBarMenuImage")?.tiffRepresentation)
    let coordinator = ImageGenerationCoordinator(
      imageProcessor: PassthroughImageProcessor(),
      imageData: { loads += 1; return data }
    )

    XCTAssertEqual(loads, 0)
    coordinator.ensureThumbnailImage()
    _ = await coordinator.thumbnailImageGenerationTask?.value
    XCTAssertEqual(loads, 1)
    XCTAssertNotNil(coordinator.thumbnailImage)

    coordinator.release(.memoryWarning)
    coordinator.ensureThumbnailImage()
    _ = await coordinator.thumbnailImageGenerationTask?.value
    XCTAssertEqual(loads, 2)
    XCTAssertNotNil(coordinator.thumbnailImage)
  }

  func testScrollOutKeepsThumbnailAndDropsPreview() async throws {
    let data = try XCTUnwrap(NSImage(named: "StatusBarMenuImage")?.tiffRepresentation)
    let coordinator = ImageGenerationCoordinator(
      imageProcessor: PassthroughImageProcessor(),
      imageData: { data }
    )
    coordinator.sizeImages()
    _ = await coordinator.thumbnailImageGenerationTask?.value
    _ = await coordinator.previewImageGenerationTask?.value

    coordinator.release(.scrollOut)

    XCTAssertNotNil(coordinator.thumbnailImage)
    XCTAssertNil(coordinator.previewImage)
    XCTAssertNil(coordinator.previewImageGenerationTask)
  }

  func testInvalidationPreventsLateByteLoad() {
    var loads = 0
    let coordinator = ImageGenerationCoordinator(
      imageProcessor: PassthroughImageProcessor(),
      imageData: { loads += 1; return Data([0]) }
    )

    coordinator.invalidate()
    coordinator.ensurePreviewImage()

    XCTAssertEqual(loads, 0)
    XCTAssertNil(coordinator.previewImageGenerationTask)
  }

  func testRepeatedEnsureKeepsOneThumbnailInFlight() async {
    let processor = CountingSuspendingImageProcessor()
    let coordinator = ImageGenerationCoordinator(
      imageProcessor: processor,
      imageData: { Data([1]) }
    )

    coordinator.ensureThumbnailImage()
    let task = coordinator.thumbnailImageGenerationTask
    coordinator.ensureThumbnailImage()
    var attempts = 0
    while attempts < 100 {
      if await processor.thumbnailCallCount() > 0 { break }
      attempts += 1
      await Task.yield()
    }
    let calls = await processor.thumbnailCallCount()

    XCTAssertEqual(calls, 1)
    coordinator.release(.invalidate)
    _ = await task?.value
  }

  func testInvalidationPreventsLatePreviewPublication() async {
    let processor = GatedPreviewProcessor()
    let coordinator = ImageGenerationCoordinator(
      imageProcessor: processor,
      imageData: { Data([1]) }
    )
    coordinator.ensurePreviewImage()
    let task = coordinator.previewImageGenerationTask
    var attempts = 0
    while attempts < 100 {
      if await processor.hasStarted() { break }
      attempts += 1
      await Task.yield()
    }

    coordinator.invalidate()
    await processor.finish()
    _ = await task?.value

    XCTAssertNil(coordinator.previewImage)
  }
}

private actor CountingSuspendingImageProcessor: ImageProcessing {
  private var thumbnailCalls = 0

  func thumbnail(for data: Data, max: CGSize) async -> NSImage? {
    thumbnailCalls += 1
    while !Task.isCancelled { await Task.yield() }
    return nil
  }

  func preview(for data: Data, max: CGSize) async -> NSImage? { nil }
  func thumbnailCallCount() -> Int { thumbnailCalls }
}

private actor GatedPreviewProcessor: ImageProcessing {
  private var started = false
  private var continuation: CheckedContinuation<Void, Never>?

  func thumbnail(for data: Data, max: CGSize) async -> NSImage? { nil }

  func preview(for data: Data, max: CGSize) async -> NSImage? {
    started = true
    await withCheckedContinuation { continuation = $0 }
    return NSImage(size: NSSize(width: 1, height: 1))
  }

  func hasStarted() -> Bool { started }

  func finish() {
    continuation?.resume()
    continuation = nil
  }
}
```

- [ ] **Step 2: Commit and obtain RED evidence**

```bash
git add MaccyTests/HistoryDecoratorTests.swift
git commit -m "test(quality): lock image coordinator lifecycle"
git push origin quality-search-corpus-projection
gh workflow run "macOS 26 ARM CI" --ref quality-search-corpus-projection
```

Expected: project generation and lint succeed; compile fails specifically because `ImageGenerationCoordinator` is absent. Inspect job status first and failed-job tail second.

### Task 2: Coordinator and decorator facade

**Files:**
- Create: `Maccy/ImageProcessing/ImageGenerationCoordinator.swift`
- Create: `MaccyTests/ImageGenerationCoordinatorTests.swift`
- Modify: `Maccy/Observables/HistoryItemDecorator.swift`
- Modify: `MaccyTests/HistoryDecoratorTests.swift` (move the RED class unchanged)

**Interfaces:**
- Consumes: `ImageProcessing`, `ReleaseReason`, `HistoryRowLayout`, image Defaults, and a lazy `@MainActor () -> Data?` provider.
- Produces: the existing decorator image API plus direct coordinator test seams.

- [ ] **Step 1: Implement coordinator-owned state and one generation pipeline**

Create a main-actor Observable final class with these members:

```swift
@MainActor
@Observable
final class ImageGenerationCoordinator {
  static var previewImageSize: NSSize
  static var thumbnailImageSize: NSSize

  @ObservationIgnored private(set) var previewImageGenerationTask: Task<Void, Never>?
  @ObservationIgnored private(set) var thumbnailImageGenerationTask: Task<Void, Never>?
  var previewImage: NSImage?
  var thumbnailImage: NSImage?
  var hasImage: Bool { get }

  init(
    imageProcessor: any ImageProcessing,
    imageData: @escaping @MainActor () -> Data?
  )

  func ensureThumbnailImage()
  func ensurePreviewImage()
  func asyncGetPreviewImage() async -> NSImage?
  func cancelPreviewGeneration()
  func sizeImages()
  func release(_ reason: ReleaseReason)
  func invalidate()
}
```

Use a private `enum Kind { case thumbnail, preview }` and one private
`startGeneration(_:) -> Task<Void, Never>?`. Capture Sendable data, processor,
and target before creating `Task { @MainActor [weak self] in ... }`. One switch
selects `processor.thumbnail` versus `processor.preview`; a second switch
publishes and records the matching DEBUG metric. Keep the invalidation guard
after the await.

- [ ] **Step 2: Replace decorator image ownership with forwarding facade**

Remove the decorator's processor, byte cache, invalidation flag, logger, task
stores, and image stores. Add:

```swift
@ObservationIgnored private let imageGeneration: ImageGenerationCoordinator

static var previewImageSize: NSSize { ImageGenerationCoordinator.previewImageSize }
static var thumbnailImageSize: NSSize { ImageGenerationCoordinator.thumbnailImageSize }
var hasImage: Bool { imageGeneration.hasImage }
var previewImageGenerationTask: Task<Void, Never>? {
  imageGeneration.previewImageGenerationTask
}
var thumbnailImageGenerationTask: Task<Void, Never>? {
  imageGeneration.thumbnailImageGenerationTask
}
var previewImage: NSImage? {
  get { imageGeneration.previewImage }
  set { imageGeneration.previewImage = newValue }
}
var thumbnailImage: NSImage? {
  get { imageGeneration.thumbnailImage }
  set { imageGeneration.thumbnailImage = newValue }
}
```

Initialize with `imageData: { item.imageData }`. Forward ensure, async preview,
cancel, and size methods. `invalidate()` calls coordinator invalidation and clears
the decorator text cache. `releaseTransientImages` calls coordinator release and
clears the text cache for every reason except `.scrollOut`.

- [ ] **Step 3: Move RED tests to the focused file and commit**

Move `ImageGenerationCoordinatorTests` byte-for-byte from
`HistoryDecoratorTests.swift` to `ImageGenerationCoordinatorTests.swift`.

```bash
git add Maccy/ImageProcessing/ImageGenerationCoordinator.swift Maccy/Observables/HistoryItemDecorator.swift MaccyTests/HistoryDecoratorTests.swift MaccyTests/ImageGenerationCoordinatorTests.swift
git commit -m "refactor(quality): isolate row image generation"
```

### Task 3: Generated project and full verification

**Files:**
- Regenerate: `Maccy.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: the two new Swift files from Task 2.
- Produces: zero-drift checked-in Xcode project and complete Debug/Release evidence.

- [ ] **Step 1: Obtain the pinned XcodeGen artifact**

Push the branch and dispatch `Regenerate and Validate Xcode Project`. The first
run is expected to fail only the committed-output drift gate while still
uploading `xcodeproj-generated-<run>-1`. Download that artifact and copy its
`Maccy.xcodeproj/project.pbxproj` into the worktree.

- [ ] **Step 2: Commit the generated project**

```bash
git add Maccy.xcodeproj/project.pbxproj
git commit -m "chore(project): register image coordinator"
git diff --check
```

- [ ] **Step 3: Run the complete feature-branch CI**

Push and dispatch one `macOS 26 ARM CI` run. Poll only after `sleep 90`.

Expected: generated-project gate, strict lint/build, all unit tests, both UI shards, and both performance shards succeed.

- [ ] **Step 4: Run the final Release package gate if the compiler plan did not already finish green at the current head**

Dispatch `Package and Release macOS App` with `publish=false`. Expected: effective optimization gate passes, Release package builds without warnings/errors, and the artifact contains `Maccy.app.zip` plus its checksum and package log.

- [ ] **Step 5: Merge code before evidence-only docs**

Fast-forward the feature branch to `master`, confirm the automatic master CI is attached to the code head, and wait for the entire matrix to pass. Only then commit audit evidence with `[skip ci]`, push it, and fast-forward the primary worktree without altering its user-owned dirty files.
