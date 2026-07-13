# Memory Governance Ownership Design

## Goal

Remove the process-wide `MemoryGovernor.shared` and `VisibilityTracker.shared`
dependencies while preserving the existing memory-pressure policy, viewport
behavior, image sizing, UI layout, and launch timing.

## Constraints

- macOS 14+ and Swift 6.0 complete strict concurrency remain unchanged.
- This machine has no local Xcode toolchain; GitHub Actions is the build, lint,
  and test authority.
- Main-list image height and preview geometry must not change.
- Memory warning behavior remains: release transient images only for
  non-visible decorators and purge the attached History's application-image
  cache.
- The dispatch memory-pressure source still starts during
  `CompositionRoot.finishLaunching` and still executes on `.main`.
- No protocol or environment-key layer is added solely for injection.

## Current Problem

`HistoryItemView` records viewport membership through
`VisibilityTracker.shared`. `MemoryGovernor.handleMemoryWarning` reads that same
global, while its dispatch callback re-enters `MemoryGovernor.shared`. Although
tests can instantiate a governor, runtime behavior is still tied to two hidden
process identities. A separately composed `AppState` therefore cannot own an
isolated viewport/memory-governance graph.

## Considered Approaches

### A. AppState tracker + CompositionRoot governor (selected)

Each `AppState` owns one `VisibilityTracker`. `HistoryItemView` already receives
its owning `AppState` from SwiftUI environment, so it registers there without a
new UI dependency mechanism. `CompositionRoot` owns one `MemoryGovernor`
constructed with that same tracker. The governor's event handler weakly captures
its own instance.

This reuses existing composition seams, removes both globals, and keeps memory
policy out of `History`.

### B. History-owned viewport resources

`History` could own the tracker and expose register/unregister operations.
However, viewport membership is UI lifecycle state; putting it in `History`
would broaden the facade immediately after B2–B5 split its responsibilities.

### C. Dedicated SwiftUI environment value

A custom environment key could carry the tracker directly. It would avoid an
`AppState` member but introduce a second composition mechanism, default-value
semantics, and extra preview/test setup for a single consumer that already has
`AppState`.

## Selected Architecture

### AppState

`AppState` gains a non-observed, instance-owned `visibilityTracker` supplied by
its initializer with a fresh-instance default. `AppState.shared` therefore owns
one live tracker, while every test or alternate composition gets an isolated
one.

### CompositionRoot

`CompositionRoot` owns its `MemoryGovernor` and always builds it from
`appState.visibilityTracker`; no caller can substitute a governor carrying a
different tracker. The read-only property is internal only so `@testable`
regression coverage can exercise the real composition bridge. `finishLaunching`
attaches the composed History and starts the owned governor.

### MemoryGovernor

`MemoryGovernor` requires a `VisibilityTracker` at initialization and stores it
privately. `handleMemoryWarning` reads that tracker. The dispatch event handler
weakly captures `self` and invokes the same main-actor method; it never resolves
a process singleton. The source remains owned by the governor, so the
`CompositionRoot` lifetime keeps it alive exactly as before.

### HistoryItemView

Viewport callbacks use `appState.visibilityTracker` and retain their current
ordering: register then request the thumbnail on appear; release the preview
then unregister on disappear.

## Data Flow

```text
AppState.visibilityTracker
       │                         ┌─ HistoryItemView appear/disappear
       ├─ viewport membership ◄──┘
       │
       └─ MemoryGovernor ◄─ CompositionRoot ownership
              │
              └─ memory warning → snapshot visible IDs
                   → release non-visible decorator images
                   → purge attached History icon cache
```

## Testing

- Extend `MemoryGovernanceTests` through the root-owned governor: a registered
  decorator keeps its transient preview and thumbnail while an unregistered one
  releases both, and the attached cache is purged.
- Add an AppState isolation assertion proving two AppState instances do not
  share viewport membership.
- Static gates require zero `MemoryGovernor.shared` and
  `VisibilityTracker.shared` references in production.
- Run the full `macOS 26 ARM CI` matrix once the branch is complete; poll every
  90 seconds per the user's explicit instruction.

## Non-Goals

- No change to image decode, cache budgets, thumbnail persistence, row heights,
  preview dimensions, or startup work.
- No change to which images memory pressure releases.
- No attempt to remove framework singletons such as `NSWorkspace.shared` or
  third-party keyboard-layout services.

## Self-Review

The design has no placeholders, selects one ownership path, keeps a single
tracker identity per composition, and does not introduce a new protocol or UI
injection mechanism. Tests cover both policy behavior and composition isolation.
