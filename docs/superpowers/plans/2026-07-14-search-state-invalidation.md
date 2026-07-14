# Search state invalidation implementation plan

**Goal:** Close D5 and VF-04 from the 2026-07-13 code-quality review by making
search invalidation an explicit state-boundary invariant.

**Architecture:** `HistorySearchSession` owns corpus staleness; mutations classify
input before destructive state changes.

---

### Task 1: Define RED contracts

**Files:**

- Modify: `MaccyTests/HistorySearchSessionTests.swift`
- Modify: `MaccyTests/HistoryMutationsTests.swift`

Add one test proving complete corpus replacement advances generation, and extend
the unknown-modifier no-op test to prove generation is preserved. Commit as
`test(quality): lock search invalidation boundaries`, push, and run one workflow.
The unit shard must fail exactly these two assertions.

### Task 2: Implement GREEN

**Files:**

- Modify: `Maccy/Search/HistorySearchSession.swift`
- Modify: `Maccy/Observables/HistoryMutations.swift`

Invalidate at the start of `replaceCorpus`. Resolve the history-item action
before invalidating and return immediately for a non-empty unknown chord. Commit
as `fix(quality): enforce search invalidation boundaries`.

### Task 3: Verify and integrate

Push the GREEN commit and run one complete macOS 26 ARM workflow. Poll at
90-second intervals, diagnose job-first, and allow at most one failed-job retry
for a documented contention flake. Record exact RED/GREEN evidence in
`architecture-and-root-causes.md`, commit it with `[skip ci]`, then ff-only merge
to `master` while preserving the primary worktree dirty-state sentinel.
