# BS-7.13 Explicit decorator projection implementation plan

**Goal:** Remove per-decorator recursive title/pin Observation mirrors while
preserving immediate UI projection and shortcut behavior.

**Architecture:** `HistoryItem` remains the title source of truth; the decorator
projects it directly. Pin shortcut derivation becomes an explicit decorator
operation invoked by the existing mutation/composition boundaries.

**Tech stack:** Swift 6, SwiftData, Observation, XCTest, GitHub Actions macOS 26
ARM runner.

---

### Task 1: Lock the projection contract (RED)

**Files:**

- Modify: `MaccyTests/HistoryDecoratorTests.swift`
- Modify: `MaccyTests/HistoryMutationsTests.swift`

**Step 1: Add the title projection test**

Construct a decorator, mutate `decorator.item.title`, and assert
`decorator.title` changes synchronously without yielding.

**Step 2: Add the pinned shortcut test**

Use the fake-backed mutation harness, inject a known available pin, call
`togglePin`, and assert the matching shortcut is present before the call returns.

**Step 3: Commit the tests**

Commit as `test(bs7.13): lock explicit decorator projection`.

**Step 4: Push once and verify RED on CI**

Use the automatic branch workflow. The unit shard must fail only at the two new
assertions; lint/build and unrelated shards must remain clean. Poll no more often
than every 90 seconds.

### Task 2: Replace recursive mirrors (GREEN)

**Files:**

- Modify: `Maccy/Observables/HistoryItemDecorator.swift`
- Modify: `Maccy/Observables/HistoryMutations.swift`
- Modify: `Maccy/Observables/History.swift`

**Step 1: Project title directly**

Make decorator `title` a computed read-only projection of `item.title`; remove
the initializer assignment and recursive title observer.

**Step 2: Centralize pinned shortcut derivation**

Add the narrow decorator operation, call it after a successful pin save, and
reuse it from `History.updateShortcuts`.

**Step 3: Remove recursive pin observation**

Delete both observer setup calls and both self-rearming methods. Update comments
that still describe mirrored state.

**Step 4: Commit the implementation**

Commit as `refactor(bs7.13): replace recursive decorator mirrors`.

### Task 3: Verify and record

**Files:**

- Modify: `docs/audit/architecture-and-root-causes.md`
- Modify: `docs/audit/2026-06-14/roadmap/step-7-swift6.md`

**Step 1: Push the implementation commit**

Let one automatic full workflow cover the complete branch.

**Step 2: Poll CI at 90-second intervals**

Inspect job conclusions first. For any real failure, read only the failed job's
log tail and fix the root cause; distinguish documented contention flakes.

**Step 3: Record exact evidence**

Update the current architecture reference and frozen-roadmap deviation note with
the RED and GREEN run IDs and exact behavior delivered.

**Step 4: Commit documentation without another CI run**

Commit as `docs(bs7.13): record observation projection evidence [skip ci]`.

**Step 5: Fast-forward master**

Verify the primary worktree dirty-state sentinel before and after the ff-only
merge, then push `master`.
