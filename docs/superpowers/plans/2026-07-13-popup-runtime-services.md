# Popup Runtime Services Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove every `AppState.shared` and `History.shared` reach from `Popup` while preserving its window, sizing, hotkey, and selection behavior.

**Architecture:** `Popup` owns an injected `PopupRuntimeServices` closure bundle expressed in popup-domain operations. `AppState` installs the live bundle after constructing popup, preview, and navigation; every closure captures `AppState` weakly so the new port cannot form an ownership cycle.

**Tech Stack:** Swift 6.0 strict concurrency, AppKit, Observation, KeyboardShortcuts, XCTest, GitHub Actions macOS 26 ARM runner.

## Global Constraints

- Target macOS Sonoma 14+ and Swift 6 complete strict concurrency.
- Do not run Xcode, tests, SwiftLint, or builds locally; this machine has no macOS toolchain.
- Use TDD for behavior changes: failing test commit, CI RED evidence, minimal GREEN, focused/static checks, then full CI.
- Preserve all user-visible popup behavior and existing `Task { @MainActor ... }` timing.
- Keep production `installsEventHandlers` defaulted to `true`; tests explicitly pass `false`.
- No `AppState`, `History`, `NavigationManager`, `SlideoutController`, `AppDelegate`, or panel type may appear in Popup's dependency interface.
- Commit each independently reviewable task; push only after the final full CI gate passes.
- Poll GitHub Actions no more often than once every 90 seconds.

---

## File Structure

- `Maccy/Observables/Popup.swift`: owns `PopupRuntimeServices`, popup state transitions, and calls only the injected port for outward effects.
- `Maccy/Observables/AppState.swift`: production composition of Popup's runtime port.
- `MaccyTests/PopupTests.swift`: recorder-backed unit coverage for every injected operation and state-machine branch.
- `docs/superpowers/specs/2026-07-13-popup-runtime-services-design.md`: approved boundary design.

### Task 1: Define the additive Popup runtime port

**Files:**
- Modify: `Maccy/Observables/Popup.swift`

**Interfaces:**
- Consumes: existing `PopupPosition`, popup initializer, and main-actor execution model.
- Produces: `PopupRuntimeServices`, `Popup.init(runtimeServices:installsEventHandlers:)`, and `configureRuntimeServices(_:)` for Tasks 2–3.

- [ ] **Step 1: Add the complete runtime-services value**

Insert before `Popup`:

```swift
@MainActor
struct PopupRuntimeServices {
  let selectInitialItem: @MainActor () -> Void
  let openPanel: @MainActor (CGFloat, PopupPosition) -> Void
  let closePanel: @MainActor () -> Void
  let isPanelPresented: @MainActor () -> Bool
  let requiresPreviewMinimumHeight: @MainActor () -> Bool
  let resizePanel: @MainActor (CGFloat) -> Void
  let prewarmVisibleWindow: @MainActor () -> Void
  let selectPressedShortcut: @MainActor () -> Bool
  let highlightNext: @MainActor () -> Void
  let commitSelection: @MainActor () -> Void

  static let inert = PopupRuntimeServices(
    selectInitialItem: {},
    openPanel: { _, _ in },
    closePanel: {},
    isPanelPresented: { false },
    requiresPreviewMinimumHeight: { false },
    resizePanel: { _ in },
    prewarmVisibleWindow: {},
    selectPressedShortcut: { false },
    highlightNext: {},
    commitSelection: {}
  )
}
```

- [ ] **Step 2: Add lifecycle-safe injection without changing behavior**

Add Popup storage and replace its initializer with:

```swift
@ObservationIgnored private var runtimeServices: PopupRuntimeServices

init(
  runtimeServices: PopupRuntimeServices = .inert,
  installsEventHandlers: Bool = true
) {
  self.runtimeServices = runtimeServices
  if installsEventHandlers {
    KeyboardShortcuts.onKeyDown(for: .popup, action: handleFirstKeyDown)
    initEventsMonitor()
  }
}

func configureRuntimeServices(_ runtimeServices: PopupRuntimeServices) {
  self.runtimeServices = runtimeServices
}
```

Do not route existing global accesses yet; this task is an additive compile-safe seam.

- [ ] **Step 3: Run static checks**

Run:

```bash
git diff --check
rg -n "PopupRuntimeServices|installsEventHandlers|configureRuntimeServices" Maccy/Observables/Popup.swift
```

Expected: no whitespace errors and exactly the new port/lifecycle symbols.

- [ ] **Step 4: Commit the additive seam**

```bash
git add Maccy/Observables/Popup.swift
git commit -m "refactor(quality): define popup runtime port"
```

### Task 2: Define all port behavior with one RED batch

**Files:**
- Modify: `MaccyTests/PopupTests.swift`

**Interfaces:**
- Consumes: `PopupRuntimeServices` and `Popup(runtimeServices:installsEventHandlers:)` from Task 1.
- Produces: deterministic tests for window operations, preview sizing, prewarm, shortcut handling, cycling, and commit selection.

- [ ] **Step 1: Add the recorder fixture**

Add below `PopupTests`:

```swift
@MainActor
private final class PopupRuntimeRecorder {
  var initialSelectionCalls = 0
  var openedPanels: [(CGFloat, PopupPosition)] = []
  var closePanelCalls = 0
  var panelPresented = false
  var previewMinimumRequired = false
  var resizedHeights: [CGFloat] = []
  var prewarmCalls = 0
  var shortcutHandled = false
  var shortcutCalls = 0
  var highlightNextCalls = 0
  var commitSelectionCalls = 0

  var services: PopupRuntimeServices {
    PopupRuntimeServices(
      selectInitialItem: { [weak self] in self?.initialSelectionCalls += 1 },
      openPanel: { [weak self] height, position in
        self?.openedPanels.append((height, position))
      },
      closePanel: { [weak self] in self?.closePanelCalls += 1 },
      isPanelPresented: { [weak self] in self?.panelPresented == true },
      requiresPreviewMinimumHeight: { [weak self] in self?.previewMinimumRequired == true },
      resizePanel: { [weak self] in self?.resizedHeights.append($0) },
      prewarmVisibleWindow: { [weak self] in self?.prewarmCalls += 1 },
      selectPressedShortcut: { [weak self] in
        self?.shortcutCalls += 1
        return self?.shortcutHandled == true
      },
      highlightNext: { [weak self] in self?.highlightNextCalls += 1 },
      commitSelection: { [weak self] in self?.commitSelectionCalls += 1 }
    )
  }
}
```

- [ ] **Step 2: Add window and sizing behavior tests**

Add to `PopupTests`:

```swift
func testInjectedRuntimeOwnsWindowAndSizingEffects() {
  let recorder = PopupRuntimeRecorder()
  let popup = Popup(runtimeServices: recorder.services, installsEventHandlers: false)
  let savedWindowSize = Defaults[.windowSize]
  let savedMaxVisibleItems = Defaults[.maxVisibleItems]
  defer {
    Defaults[.windowSize] = savedWindowSize
    Defaults[.maxVisibleItems] = savedMaxVisibleItems
  }
  Defaults[.windowSize] = NSSize(width: 450, height: 800)
  Defaults[.maxVisibleItems] = 100

  popup.open(height: 120, at: .cursor)
  XCTAssertEqual(recorder.initialSelectionCalls, 1)
  XCTAssertEqual(recorder.openedPanels.count, 1)
  XCTAssertEqual(recorder.openedPanels.first?.0, 120)
  XCTAssertEqual(recorder.openedPanels.first?.1, .cursor)

  XCTAssertTrue(popup.isClosed())
  recorder.panelPresented = true
  XCTAssertFalse(popup.isClosed())
  popup.close()
  XCTAssertEqual(recorder.closePanelCalls, 1)

  recorder.previewMinimumRequired = true
  XCTAssertEqual(popup.preferredHeight(for: 10), Popup.minimumPreviewHeight)
  popup.resize(height: 120)
  XCTAssertEqual(recorder.resizedHeights, [120])
}
```

- [ ] **Step 3: Add hotkey state-machine behavior tests**

Add to `PopupTests`:

```swift
func testInjectedRuntimeOwnsOpenCycleAndCommitEffects() {
  let recorder = PopupRuntimeRecorder()
  let popup = Popup(runtimeServices: recorder.services, installsEventHandlers: false)

  popup.handleTestingHotKeyDown()
  XCTAssertEqual(recorder.prewarmCalls, 1)
  XCTAssertEqual(recorder.initialSelectionCalls, 1)
  XCTAssertEqual(recorder.openedPanels.count, 1)

  recorder.panelPresented = true
  popup.handleTestingHotKeyDown()
  XCTAssertEqual(recorder.highlightNextCalls, 1)
  popup.handleTestingModifiersReleased()
  XCTAssertEqual(recorder.commitSelectionCalls, 1)
}

func testHandledShortcutStopsCycleAndClosePaths() {
  let recorder = PopupRuntimeRecorder()
  recorder.panelPresented = true
  recorder.shortcutHandled = true
  let popup = Popup(runtimeServices: recorder.services, installsEventHandlers: false)

  popup.handleTestingHotKeyDown()

  XCTAssertEqual(recorder.shortcutCalls, 1)
  XCTAssertEqual(recorder.highlightNextCalls, 0)
  XCTAssertEqual(recorder.closePanelCalls, 0)
}
```

- [ ] **Step 4: Commit and push the RED batch**

```bash
git add MaccyTests/PopupTests.swift
git commit -m "test(quality): define popup runtime boundary"
git push -u origin quality-popup-runtime-services
gh workflow run "macOS 26 ARM CI" --ref quality-popup-runtime-services
```

Expected: project generation and lint/build succeed, then the unit shard fails only in the new tests because Popup still calls global collaborators. Cancel remaining shards after confirming the exact failures.

### Task 3: Route Popup exclusively through the runtime port

**Files:**
- Modify: `Maccy/Observables/Popup.swift`
- Modify: `Maccy/Observables/AppState.swift`

**Interfaces:**
- Consumes: every `PopupRuntimeServices` operation tested in Task 2.
- Produces: Popup with zero global AppState/History reach and production wiring owned by AppState.

- [ ] **Step 1: Replace Popup's global window and sizing accesses**

Use these exact bodies:

```swift
func open(height: CGFloat, at popupPosition: PopupPosition = Defaults[.popupPosition]) {
  runtimeServices.selectInitialItem()
  runtimeServices.openPanel(height, popupPosition)
}

func close() {
  runtimeServices.closePanel()
}

func isClosed() -> Bool {
  !runtimeServices.isPanelPresented()
}
```

In `preferredHeight`, replace the global preview/navigator condition with
`runtimeServices.requiresPreviewMinimumHeight()`. In `resize`, replace the
panel call with `runtimeServices.resizePanel(preferredHeight(for: self.height))`.
In the closed hotkey path call `runtimeServices.prewarmVisibleWindow()`.

- [ ] **Step 2: Replace shortcut, cycle, and commit accesses**

Use:

```swift
if runtimeServices.selectPressedShortcut() {
  return nil
}
```

Replace navigation cycling with `runtimeServices.highlightNext()`. Preserve the
existing deferred selection timing with:

```swift
Task { @MainActor [runtimeServices] in
  runtimeServices.commitSelection()
}
```

- [ ] **Step 3: Make the event monitor instance-owned**

Change the local monitor closure to capture `[weak self]` and decide through:

```swift
let consume = MainActor.assumeIsolated {
  self?.shouldConsumeFlagsChanged(allReleased: allReleased) ?? false
}
```

Update the deinit comment so it no longer claims Popup is necessarily
`AppState.shared.popup`.

- [ ] **Step 4: Compose live services at the end of AppState initialization**

After `history.configureUIEffectSink`, configure all operations with weak owner
capture:

```swift
popup.configureRuntimeServices(PopupRuntimeServices(
  selectInitialItem: { [weak self] in
    guard let self else { return }
    self.navigator.select(
      item: self.history.unpinnedItems.first ?? self.history.pinnedItems.first
    )
  },
  openPanel: { [weak self] height, position in
    self?.appDelegate?.panel.open(height: height, at: position)
  },
  closePanel: { [weak self] in self?.appDelegate?.panel.close() },
  isPanelPresented: { [weak self] in self?.appDelegate?.panel.isPresented == true },
  requiresPreviewMinimumHeight: { [weak self] in
    guard let self else { return false }
    return self.preview.state.isOpen && self.navigator.leadSelection != nil
  },
  resizePanel: { [weak self] height in self?.appDelegate?.panel.verticallyResize(to: height) },
  prewarmVisibleWindow: { [weak self] in self?.prewarmVisibleWindow() },
  selectPressedShortcut: { [weak self] in
    guard let self, let item = self.history.pressedShortcutItem else { return false }
    self.navigator.select(item: item)
    Task { @MainActor [weak self] in self?.history.select(item) }
    return true
  },
  highlightNext: { [weak self] in self?.navigator.highlightNext(allowCycle: true) },
  commitSelection: { [weak self] in self?.select() }
))
```

- [ ] **Step 5: Run static structural gates**

```bash
git diff --check
test -z "$(rg -n 'AppState\.shared|History\.shared' Maccy/Observables/Popup.swift)"
rg -n "runtimeServices\." Maccy/Observables/Popup.swift
```

Expected: no whitespace errors, no global reach, and every outward effect goes
through `runtimeServices`.

- [ ] **Step 6: Commit GREEN**

```bash
git add Maccy/Observables/Popup.swift Maccy/Observables/AppState.swift
git commit -m "refactor(quality): inject popup runtime services"
git push origin quality-popup-runtime-services
```

### Task 4: Verify and integrate

**Files:**
- Verify only; no planned code changes.

**Interfaces:**
- Consumes: completed Popup runtime boundary.
- Produces: CI-green commit ready for fast-forward integration.

- [ ] **Step 1: Run the complete branch workflow once**

```bash
gh workflow run "macOS 26 ARM CI" --ref quality-popup-runtime-services
```

Poll at 90-second intervals. Expected: Generated Xcode project, Lint +
diagnostics, unit, ui-1, ui-2, perf-text, and perf-image all succeed.

- [ ] **Step 2: Re-run structural and repository checks**

```bash
test -z "$(rg -n 'AppState\.shared|History\.shared' Maccy/Observables/Popup.swift)"
git diff --check origin/master...HEAD
git status --short --branch
```

Expected: no global Popup reach, no whitespace errors, clean worktree.

- [ ] **Step 3: Fast-forward master and monitor its automatic workflow**

```bash
git fetch origin master
test "$(git merge-base origin/master HEAD)" = "$(git rev-parse origin/master)"
git push origin HEAD:master
```

Expected: fast-forward push. Monitor the automatically triggered master workflow
at 90-second intervals until all seven jobs succeed.
