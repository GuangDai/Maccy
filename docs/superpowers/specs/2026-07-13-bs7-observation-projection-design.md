# BS-7.13 Explicit decorator projection design

## Context

`HistoryItemDecorator` currently duplicates `HistoryItem.title` in a stored
property and installs two self-rearming `withObservationTracking` chains for
`title` and `pin`. Each model mutation schedules a `DispatchQueue.main.async`
callback, updates decorator state later, then recursively installs another
observer. With a decorator for every history row, this creates two long-lived
implicit callback chains per row and makes update timing depend on an extra main
queue turn.

The current architecture already has explicit mutation and projection
boundaries:

- `HistoryMutations` is the only production owner of user-driven pin changes.
- `History` owns the `showSpecialSymbols` title rewrite.
- `HistoryStoreProjector` replaces a decorator for incremental store events and
  reuses the existing model instance during full reconciliation.
- `HistoryItem.title` is already observable through SwiftData.

The recursive mirror is therefore duplicate state, not the source of truth.

## Goals

- Remove both recursive Observation callback chains from every decorator.
- Make `title` a direct, immediately readable projection of the backing model.
- Update the pinned shortcut explicitly at the successful pin mutation boundary.
- Preserve pin ordering, unpinned numeric shortcuts, search corpus updates,
  persisted behavior, and all user-visible UI behavior.
- Do not add fetches, load more history, delay startup, or change image/preview
  sizing.

## Non-goals

- Redesign pin allocation or shortcut rules.
- Change the SwiftData schema or actor topology.
- Change search behavior or model loading/windowing.
- Remove the `HistoryItem` model from the decorator.

## Selected design

### Title: eliminate the duplicate state

Replace the decorator's stored `title` with a read-only computed projection of
`item.title`. Callers still use `decorator.title`; they simply observe/read the
real source instead of a delayed copy. The `History` setting watcher writes only
the model title before rebuilding the search corpus.

Because the getter reads the SwiftData model property, Swift Observation tracks
the actual title dependency when SwiftUI evaluates the view. Reads immediately
after a model mutation also return the new value without waiting for a queued
mirror callback.

### Pin: synchronize at the command boundary

Add a narrow decorator operation that derives the pinned shortcut from
`item.pin`. `HistoryMutations.togglePin` invokes it only after persistence
succeeds; rollback leaves the projection unchanged. `History.updateShortcuts`
uses the same operation when shortcut modifiers change, keeping the pin-to-key
mapping in one place. The existing unpinned shortcut pass remains authoritative
for numeric slots after unpinning.

### Lifecycle

Decorator initialization no longer starts observers. Invalidation therefore no
longer has recursive callbacks that can re-arm after teardown. Image task
lifecycle and row visibility tracking remain unchanged.

## Alternatives considered

1. Keep the stored title and replace recursion with an `AsyncStream` task. This
   still duplicates the model value and keeps one task per projection, so it
   changes mechanism without removing the coupling.
2. Keep recursive Observation but add generation/cancellation tokens. This
   makes teardown safer but retains delayed updates and two callback chains per
   row.
3. Move all model fields into DTO-only decorators. This is a much larger storage
   redesign and would overlap the rejected D1/windowing direction; it is not
   needed for BS-7.13.

## Verification

TDD must first demonstrate two failures on the current implementation:

1. Mutating the backing model title is visible through `decorator.title` before
   any `Task.yield` or main-queue turn.
2. A successful unpinned-to-pinned mutation publishes the injected pin shortcut
   before `togglePin` returns.

Then the full macOS 26 ARM CI matrix is the compile/test/lint gate. No local
Xcode, SwiftLint, or tests are run on this machine.
