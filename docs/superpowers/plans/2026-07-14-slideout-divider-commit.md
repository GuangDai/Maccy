# Transactional Slideout Divider Resize Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep divider dragging visually live while persisting content and preview widths only once at gesture end.

**Architecture:** `SlideoutController` owns a short-lived divider transaction with a stable starting width. The SwiftUI view forwards gesture values; only the controller's finish operation crosses the persistence callback seam.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI, AppKit, XCTest, GitHub macOS 26 ARM CI.

## Global Constraints

- Preserve both 200-point column floors and left/right divider direction.
- Do not change window-edge resize, preview/window height, image row height, or startup work.
- Write RED first and verify it on CI before production code.
- Run no Xcode or SwiftLint commands locally; poll CI every 90 seconds.

---

### Task 1: Lock the divider transaction contract

**Files:**

- Modify: `MaccyTests/HistoryUIEffectTests.swift`

**Interfaces:**

- Consumes: `SlideoutController` callback initializer and observable widths.
- Produces: desired `updateDividerResize(translation:totalWidth:)` and `finishDividerResize()` interface.

- [ ] **Step 1: Add the failing controller test**

In `SlideoutRuntimeTests`, record each callback, establish 400/400 widths, clear
the setup calls, then apply cumulative right-placement translations of 40 and
80 points in an 800-point window:

```swift
func testDividerResizePersistsOnlyOnceAtFinish() {
  var contentWrites: [CGFloat] = []
  var slideoutWrites: [CGFloat] = []
  let controller = SlideoutController(
    onContentResize: { contentWrites.append($0) },
    onSlideoutResize: { slideoutWrites.append($0) }
  )
  controller.contentWidth = 400
  controller.slideoutWidth = 400
  contentWrites.removeAll()
  slideoutWrites.removeAll()

  controller.updateDividerResize(translation: 40, totalWidth: 800)
  controller.updateDividerResize(translation: 80, totalWidth: 800)

  XCTAssertEqual(controller.contentWidth, 480)
  XCTAssertEqual(controller.slideoutWidth, 320)
  XCTAssertTrue(contentWrites.isEmpty)
  XCTAssertTrue(slideoutWrites.isEmpty)

  controller.finishDividerResize()
  controller.finishDividerResize()

  XCTAssertEqual(contentWrites, [480])
  XCTAssertEqual(slideoutWrites, [320])
}
```

- [ ] **Step 2: Commit and verify RED**

```bash
git add MaccyTests/HistoryUIEffectTests.swift
git commit -m "test(quality): lock divider resize transaction"
```

Push the branch and dispatch one workflow after the current master workflow has
completed. Expected failure: only the two missing controller operations.

### Task 2: Implement the controller-owned transaction

**Files:**

- Modify: `Maccy/Observables/SlideoutController.swift`
- Modify: `Maccy/Views/SlideoutView.swift`

**Interfaces:**

- Consumes: the RED test from Task 1.
- Produces: transient observable width updates and one persistence commit.

- [ ] **Step 1: Add controller transaction state and operations**

Add an observation-ignored optional starting width. The update operation derives
every frame from that stable base and mutates backing widths without callbacks:

```swift
@ObservationIgnored private var dividerDragStartSlideoutWidth: CGFloat?

func updateDividerResize(translation: CGFloat, totalWidth: CGFloat) {
  let startingWidth = dividerDragStartSlideoutWidth ?? slideoutWidth
  dividerDragStartSlideoutWidth = startingWidth
  let direction: CGFloat = placement == .right ? -1 : 1
  let maximumSlideoutWidth = max(minimumSlideoutWidth, totalWidth - minimumContentWidth)
  _slideoutWidth = min(
    max(minimumSlideoutWidth, startingWidth + direction * translation),
    maximumSlideoutWidth
  ).rounded()
  _contentWidth = max(minimumContentWidth, totalWidth - _slideoutWidth).rounded()
}

func finishDividerResize() {
  guard dividerDragStartSlideoutWidth != nil else { return }
  dividerDragStartSlideoutWidth = nil
  onSlideoutResize(_slideoutWidth)
  onContentResize(_contentWidth)
}
```

- [ ] **Step 2: Make the view a gesture adapter**

Replace the width calculations in `onChanged` with:

```swift
guard let totalWidth = controller.window?.frame.width else { return }
controller.updateDividerResize(
  translation: value.translation.width,
  totalWidth: totalWidth
)
```

Replace both assignments in `onEnded` with `controller.finishDividerResize()`.

- [ ] **Step 3: Commit GREEN**

```bash
git add Maccy/Observables/SlideoutController.swift Maccy/Views/SlideoutView.swift
git commit -m "fix(quality): commit divider widths once"
```

### Task 3: Verify, document, and integrate

**Files:**

- Modify: `docs/audit/architecture-and-root-causes.md`
- Modify: `docs/superpowers/specs/2026-07-14-slideout-divider-commit-design.md`

- [ ] **Step 1: Run the complete GREEN workflow**

Require project generation, strict lint/build, unit/UI shards, and performance
shards to pass. Retry only one failed job for a documented contention flake.

- [ ] **Step 2: Self-review the full diff**

Run `git diff 3153161f..HEAD --check`. Confirm no `.onChanged` path invokes the
committed setters/callbacks, cumulative translation uses a stable base, finish
is idempotent, and the NSWindow resize path is unchanged.

- [ ] **Step 3: Record exact RED/GREEN evidence**

Commit evidence separately with `[skip ci]`, but push the green code commit to
master first so a documentation head cannot suppress the automatic code run.

- [ ] **Step 4: Preserve the primary worktree and fast-forward master**

Verify the five-entry primary dirty-state sentinel before and after merge, then
push code once and the evidence-only commit separately.
