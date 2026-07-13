# Unpinned Shortcut Diff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve visible unpinned 1–9 shortcuts while suppressing all no-op shortcut assignments and their Observation notifications.

**Architecture:** Keep `HistoryMutations.updateUnpinnedShortcuts()` as the sole interface. Its implementation walks visible unpinned decorators once, derives each desired shortcut array, compares binding semantics privately by key and modifier flags, and assigns only changed bindings.

**Tech Stack:** Swift 6.0 complete strict concurrency, Swift Observation, AppKit modifier flags, XCTest, GitHub Actions macOS 26 ARM runner.

## Global Constraints

- Preserve user-visible shortcut ordering and modifier variants.
- Preserve `KeyShortcut` UUID identity while a binding remains unchanged.
- Keep all work on the main actor and add no startup work.
- Do not change popup layout, row height, image sizing, search publication, or pin behavior.
- Do not add stored shortcut state to `HistoryItemDecorator` or broaden `KeyShortcut` with `Equatable` solely for this caller.
- Do not build, test, or lint locally; this machine has no Xcode/macOS toolchain.
- Run only one GitHub Actions workflow at a time and poll each run only after `sleep 90`.
- Keep the primary worktree's pre-existing dirty files untouched.

---

### Task 1: Diff shortcut bindings through the existing mutation interface

**Files:**
- Modify: `MaccyTests/HistoryMutationsTests.swift`
- Modify: `Maccy/Observables/HistoryMutations.swift:234-242`
- Modify: `docs/audit/architecture-and-root-causes.md:150`

**Interfaces:**
- Consumes: `HistoryListState.items`, `HistoryItemDecorator.isUnpinned`, `HistoryItemDecorator.isVisible`, `HistoryItemDecorator.shortcuts`, and `KeyShortcut.create(character:)`.
- Produces: unchanged `HistoryMutations.updateUnpinnedShortcuts() -> Void`; private binding-semantic comparison only.

- [ ] **Step 1: Add RED Observation and transition tests**

Add `import Observation` to `MaccyTests/HistoryMutationsTests.swift`. Add these tests inside `HistoryMutationsTests`:

```swift
  func testUpdateUnpinnedShortcutsDoesNotPublishWhenBindingsAreStable() async {
    let decorators = (0..<10).map { decorator(item(title: "item-\($0)")) }
    let harness = makeHarness(decorators)
    harness.subject.updateUnpinnedShortcuts()
    let probes = decorators.map(ShortcutObservationProbe.init)

    harness.subject.updateUnpinnedShortcuts()
    await Task.yield()

    XCTAssertEqual(probes.map(\.changeCount), Array(repeating: 0, count: 10))
    for (index, decorator) in decorators.prefix(9).enumerated() {
      assertShortcuts(decorator.shortcuts, match: String(index + 1))
    }
    XCTAssertTrue(decorators[9].shortcuts.isEmpty)
  }

  func testUpdateUnpinnedShortcutsPublishesOnlyChangedBindings() async {
    let decorators = (0..<10).map { decorator(item(title: "item-\($0)")) }
    let harness = makeHarness(decorators)
    harness.subject.updateUnpinnedShortcuts()
    let probes = decorators.map(ShortcutObservationProbe.init)
    var reordered = decorators
    reordered.swapAt(0, 9)
    harness.listState.publishVisible(reordered)

    harness.subject.updateUnpinnedShortcuts()
    await Task.yield()

    XCTAssertEqual(probes.map(\.changeCount), [1, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    assertShortcuts(decorators[9].shortcuts, match: "1")
    XCTAssertTrue(decorators[0].shortcuts.isEmpty)
    for index in 1..<9 {
      assertShortcuts(decorators[index].shortcuts, match: String(index + 1))
    }
  }
```

Add this assertion helper inside the test class:

```swift
  private func assertShortcuts(
    _ actual: [KeyShortcut],
    match character: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let expected = KeyShortcut.create(character: character)
    XCTAssertEqual(actual.count, expected.count, file: file, line: line)
    for (actual, expected) in zip(actual, expected) {
      XCTAssertEqual(actual.key, expected.key, file: file, line: line)
      XCTAssertEqual(actual.modifierFlags, expected.modifierFlags, file: file, line: line)
    }
  }
```

Add this one-shot probe at file scope beside the existing private test helpers:

```swift
@MainActor
private final class ShortcutObservationProbe {
  private(set) var changeCount = 0

  init(_ item: HistoryItemDecorator) {
    withObservationTracking {
      _ = item.shortcuts
    } onChange: {
      Task { @MainActor [weak self] in
        self?.changeCount += 1
      }
    }
  }
}
```

- [ ] **Step 2: Commit and verify the RED behavior on GitHub Actions**

Run only static local checks:

```bash
git diff --check
git add MaccyTests/HistoryMutationsTests.swift
git commit -m "test(quality): lock unpinned shortcut diff"
```

After the preceding workflow has completed, push the branch and manually run
`macOS 26 ARM CI`. Poll only after `sleep 90`. Expected: generated project,
lint, and compilation succeed; the unit shard fails specifically because the
old clear-then-rebuild implementation publishes changes to stable decorators.
Record the run ID and failed assertions in `.superpowers/sdd/task-1-report.md`.

- [ ] **Step 3: Replace the double pass with the minimal semantic diff**

Replace `updateUnpinnedShortcuts` in
`Maccy/Observables/HistoryMutations.swift` with:

```swift
  func updateUnpinnedShortcuts() {
    for (index, item) in listState.items.lazy
      .filter({ $0.isUnpinned && $0.isVisible })
      .enumerated() {
      let desired = index < 9
        ? KeyShortcut.create(character: String(index + 1))
        : []
      guard !haveSameBindings(item.shortcuts, desired) else {
        continue
      }
      item.shortcuts = desired
    }
  }

  private func haveSameBindings(_ lhs: [KeyShortcut], _ rhs: [KeyShortcut]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
      $0.key == $1.key && $0.modifierFlags == $1.modifierFlags
    }
  }
```

This comparison intentionally ignores `KeyShortcut.id`: equal bindings keep
the existing array and stable UUIDs; changed bindings receive a newly created
array exactly once.

- [ ] **Step 4: Update the authoritative diagnosis row**

In `docs/audit/architecture-and-root-causes.md`, replace the
`updateunpinned-double-pass` `[未修]` row with a pending evidence row stating:

```markdown
| `updateUnpinnedShortcuts` 双遍赋值 | [待 CI] | 单遍计算可见 unpinned 项的目标 1–9 bindings，并仅在 key/modifier 语义变化时赋值；不变项保留 shortcut UUID 且不发 Observation 通知。full matrix 待验证。 |
```

- [ ] **Step 5: Review, commit, and run the full green gate**

Run the source-level gates only:

```bash
git diff --check
rg -n "func updateUnpinnedShortcuts|haveSameBindings" \
  Maccy/Observables/HistoryMutations.swift MaccyTests/HistoryMutationsTests.swift
git add Maccy/Observables/HistoryMutations.swift \
  MaccyTests/HistoryMutationsTests.swift \
  docs/audit/architecture-and-root-causes.md
git commit -m "refactor(quality): diff unpinned shortcuts"
```

Create the SDD review package, obtain independent spec and quality review, and
close every Critical/Important finding. Push the branch, manually run one full
`macOS 26 ARM CI` matrix, and poll only after `sleep 90`. Required success jobs:
Generated Xcode project, Lint + diagnostics, unit, ui-1, ui-2, perf-text, and
perf-image.

- [ ] **Step 6: Record exact CI evidence**

After the full matrix succeeds, change the architecture row to `[已修]`, add the
run ID, and commit without starting a docs-only CI:

```bash
git add docs/audit/architecture-and-root-causes.md
git commit -m "docs(quality): record shortcut diff CI evidence"
```

Fast-forward the reviewed branch into `master` while asserting the primary
worktree's pre-existing dirty status is byte-for-byte unchanged, then push
`master`.
