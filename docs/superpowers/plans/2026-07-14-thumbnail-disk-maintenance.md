# Incremental Thumbnail Disk Maintenance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove per-thumbnail full-directory scans and stop cancelled thumbnail work before PNG disk I/O.

**Architecture:** Keep `ThumbnailCache` as the sole actor owner of memory and disk state. Add a pure actor-owned byte ledger that requests inventory only while unknown or over budget, and add one internal downsample seam so post-decode cancellation is deterministic under test.

**Tech Stack:** Swift 6 strict concurrency, AppKit, ImageIO, XCTest, GitHub macOS 26 ARM CI.

## Global Constraints

- Do not add startup work; directory inventory is lazy on the first successful write.
- Preserve the external `ThumbnailCache.thumbnail` / `evict` interfaces and the 256 MiB soft budget.
- Preserve modification-date LRU behavior, memory-cache limits, and `(fingerprint, maxPixelSize)` keys.
- Do not alter main-list image height, preview height, or any other user-visible geometry.
- Use TDD: commit RED tests first, then the minimum GREEN implementation.
- Do not run Xcode, tests, or SwiftLint locally; use the macOS 26 ARM workflow and poll every 90 seconds.

---

### Task 1: Lock byte-accounting and cancellation contracts

**Files:**

- Modify: `MaccyTests/ThumbnailCacheTests.swift`

**Interfaces:**

- Consumes: existing `ThumbnailCache.thumbnail(for:data:max:)` behavior.
- Produces: desired `ThumbnailDiskUsageLedger` transition interface and the internal `ThumbnailCache` downsample initializer seam.

- [ ] **Step 1: Add failing ledger tests**

Add two synchronous tests. The first requires an inventory for an unknown
ledger, records `40` bytes, then verifies another `30` byte write under a `100`
byte budget requires no inventory. The second starts at `70`, verifies a `31`
byte write requests inventory, records an authoritative `101`, removes `40`,
and verifies the total is `61`:

```swift
func testDiskUsageLedgerInventoriesOnlyWhenUnknownOrOverBudget() {
  var ledger = ThumbnailDiskUsageLedger(budget: 100)

  XCTAssertEqual(ledger.recordWrite(replacing: 0, with: 40), .inventory)
  ledger.recordInventory(totalBytes: 40)
  XCTAssertEqual(ledger.recordWrite(replacing: 0, with: 30), .none)
  XCTAssertEqual(ledger.totalBytes, 70)
}

func testDiskUsageLedgerTracksOverBudgetInventoryAndRemoval() {
  var ledger = ThumbnailDiskUsageLedger(budget: 100)
  ledger.recordInventory(totalBytes: 70)

  XCTAssertEqual(ledger.recordWrite(replacing: 0, with: 31), .inventory)
  ledger.recordInventory(totalBytes: 101)
  ledger.recordRemoval(bytes: 40)

  XCTAssertEqual(ledger.totalBytes, 61)
}
```

- [ ] **Step 2: Add the failing post-downsample cancellation test**

Create a cache whose injected closure performs the real downsample and cancels
only the child task running the lookup. Assert `nil` and an empty directory:

First extract the temporary-URL construction already used by `makeCache` into
`makeDirectory()`, then let `makeCache` call that helper.

```swift
func testCancellationAfterDownsampleSkipsDiskWrite() async throws {
  let dir = temporaryDirectory()
  let cache = ThumbnailCache(diskDirectory: dir, downsample: { data, maxPixelSize in
    let image = ImageDownsampler.thumbnail(data: data, max: maxPixelSize)
    withUnsafeCurrentTask { $0?.cancel() }
    return image
  })
  let data = try FixtureLoader.imageData()

  let result = await Task {
    await cache.thumbnail(for: fingerprint(5), data: data, max: 50)
  }.value

  XCTAssertNil(result)
  XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
}
```

Keep temporary-directory construction in the existing test helper so every
test remains isolated.

- [ ] **Step 3: Commit RED**

```bash
git add MaccyTests/ThumbnailCacheTests.swift
git commit -m "test(quality): lock thumbnail disk maintenance"
```

- [ ] **Step 4: Push and verify RED on CI**

Run the workflow once on the branch. Expected failure: missing
`ThumbnailDiskUsageLedger` and the new `downsample` initializer argument; no
unrelated diagnostic is acceptable.

### Task 2: Implement incremental maintenance and cooperative cancellation

**Files:**

- Modify: `Maccy/ImageProcessing/ThumbnailCache.swift`

**Interfaces:**

- Consumes: the tests from Task 1.
- Produces: `ThumbnailDiskUsageLedger`, lazy inventory, and a post-downsample cancellation checkpoint while leaving cache callers unchanged.

- [ ] **Step 1: Add the pure ledger**

Define an internal value module near `ThumbnailCache`:

```swift
struct ThumbnailDiskUsageLedger {
  enum Maintenance: Equatable {
    case none
    case inventory
  }

  let budget: Int
  private(set) var totalBytes: Int?

  mutating func recordWrite(replacing previousBytes: Int?, with currentBytes: Int?) -> Maintenance {
    guard let totalBytes, let previousBytes, let currentBytes else {
      return .inventory
    }
    self.totalBytes = max(0, totalBytes - max(0, previousBytes) + max(0, currentBytes))
    return (self.totalBytes ?? 0) > budget ? .inventory : .none
  }

  mutating func recordRemoval(bytes: Int?) {
    guard let totalBytes, let bytes else {
      self.totalBytes = nil
      return
    }
    self.totalBytes = max(0, totalBytes - max(0, bytes))
  }

  mutating func recordInventory(totalBytes: Int) {
    self.totalBytes = max(0, totalBytes)
  }
}
```

- [ ] **Step 2: Add the internal downsample seam and cancellation checkpoint**

Store a `@Sendable (Data, CGFloat) -> CGImage?` closure defaulting to
`ImageDownsampler.thumbnail`. In `thumbnail`, call it instead of the static
method, then immediately guard `!Task.isCancelled` before measuring or writing
the disk file. A cancelled operation returns `nil` and publishes nothing.

- [ ] **Step 3: Make disk writes report accounting data**

Measure the prior file size, finalize the PNG, and measure the resulting size.
Feed both optionals into `recordWrite`. A failed PNG finalization preserves the
existing behavior of returning/memory-caching the decoded image but does not
mutate the ledger.

- [ ] **Step 4: Replace per-write eviction with requested inventory**

Rename the old operation to `inventoryAndEvictIfNeeded`. It scans once, totals
all entries, sorts only when over budget, subtracts only after a successful
remove, and finally calls `recordInventory(totalBytes:)`. Invoke it only when
the ledger returns `.inventory`.

- [ ] **Step 5: Account for explicit eviction**

Before `removeItem`, measure the file. After successful removal, call
`recordRemoval(bytes:)`; do not inventory immediately when the size was
unavailable—the ledger becomes unknown and the next successful write repairs
it lazily.

- [ ] **Step 6: Commit GREEN**

```bash
git add Maccy/ImageProcessing/ThumbnailCache.swift
git commit -m "fix(quality): make thumbnail disk maintenance incremental"
```

### Task 3: Verify and integrate

**Files:**

- Modify: `docs/audit/architecture-and-root-causes.md`
- Modify: `docs/superpowers/specs/2026-07-14-thumbnail-disk-maintenance-design.md`

**Interfaces:**

- Consumes: Task 2 production behavior and complete CI evidence.
- Produces: an evidence-backed architecture record and a clean fast-forward to `master`.

- [ ] **Step 1: Run the full workflow**

Push GREEN and run one macOS 26 ARM workflow. Project generation, strict lint
and diagnostics, all unit/UI shards, and all performance shards must pass.
Allow at most one failed-job retry only for a documented runner-contention
flake, after inspecting the failed job tail.

- [ ] **Step 2: Self-review**

Run `git diff 7a2c32e2..HEAD --check` and review the complete diff. Confirm cache
construction performs only directory creation, disk hits do not inventory, the
post-downsample checkpoint precedes all file mutations, and the external cache
interface is unchanged.

- [ ] **Step 3: Record evidence and commit without another CI run**

Append exact RED/GREEN run IDs and test counts to the spec and architecture
reference, then commit:

```bash
git commit -am "docs(quality): record thumbnail maintenance evidence [skip ci]"
```

- [ ] **Step 4: Preserve the primary worktree and integrate**

Verify the primary dirty-state sentinel is unchanged, fast-forward `master`,
push once, and let the automatic master workflow run without dispatching a
duplicate workflow.
