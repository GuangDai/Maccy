# Unpinned Shortcut Diff Design

## Goal

Replace `HistoryMutations.updateUnpinnedShortcuts`' clear-then-rebuild writes
with one semantic diff pass. Preserve the visible 1–9 shortcut behavior while
avoiding Observation notifications for decorators whose shortcut bindings did
not change.

## Constraints

- Preserve user-visible shortcut ordering and modifier variants.
- Preserve `KeyShortcut` UUID identity while a binding remains unchanged.
- Keep all work on the main actor and add no startup work.
- Do not change popup layout, row height, image sizing, search publication, or
  pin behavior.
- Do not introduce another stored shortcut slot on `HistoryItemDecorator`.
- This machine has no local Xcode toolchain; GitHub Actions remains the build,
  lint, and test authority.

## Current Problem

`updateUnpinnedShortcuts` first assigns `[]` to every visible unpinned
decorator, then builds shortcuts for the first nine in a second loop. A stable
publication therefore sends one Observation mutation for every visible item
and a second mutation for the first nine, even though the final bindings did
not change. It also replaces the first nine shortcuts' UUID identity on every
refresh.

## Considered Approaches

### A. Private semantic diff in HistoryMutations (selected)

Walk visible unpinned decorators once. For each index, compute the desired
shortcut array (1–9 or empty), compare existing and desired bindings by key and
modifier flags, and assign only when they differ. UUID is deliberately excluded
from semantic comparison so an unchanged binding retains its existing view
identity.

This keeps the diff policy local to the module that owns the mutation and does
not expand `KeyShortcut`'s interface for a single caller.

### B. Store an unpinned shortcut slot on each decorator

An integer slot would make comparison cheap, but it duplicates information
already encoded by `shortcuts` and creates synchronization rules between two
observable states.

### C. Recompute binding rules inside HistoryMutations

Comparing the expected key and modifiers before creating shortcuts avoids a few
temporary values. It would duplicate `KeyShortcut.create`'s Defaults-dependent
modifier policy and couple mutation code to keyboard construction details.

## Selected Module Shape

`HistoryMutations` keeps its existing external interface. Its implementation
adds private helpers that:

1. derive the desired array for a visible unpinned index;
2. compare two shortcut arrays by binding semantics; and
3. assign only when that comparison differs.

The module remains deep at the existing `updateUnpinnedShortcuts()` interface:
callers continue requesting a refresh without learning diff rules, the nine-item
limit, UUID preservation, or Observation behavior.

## Data Flow

```text
listState.items
  -> visible + unpinned items (existing order)
  -> enumerate once
       -> index 0...8: desired KeyShortcut.create("1"..."9")
       -> index 9+: desired []
       -> same key/modifier bindings? keep existing array
       -> changed bindings? assign desired array once
```

## Testing

- Add an Observation regression test that primes the correct 1–9 bindings,
  tracks every decorator's `shortcuts`, refreshes again, and observes zero
  changes.
- Add a transition test that changes visible ordering/membership and verifies
  the final bindings plus notifications only for decorators whose semantic
  binding changed.
- Keep tests at `HistoryMutations.updateUnpinnedShortcuts()` rather than testing
  private comparison helpers.
- Run one full `macOS 26 ARM CI` matrix after implementation, polling every 90
  seconds.

## Non-Goals

- No new shortcut feature or configurable shortcut count.
- No broad `Equatable` conformance for `KeyShortcut`.
- No change to pinned shortcut synchronization.
- No optimization of unrelated History publication paths.

## Self-Review

The design contains no placeholders, keeps one existing interface, avoids
duplicate state and broader coupling, defines UUID semantics explicitly, and
locks both final behavior and suppressed no-op notifications through the module
interface.
