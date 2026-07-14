# Transactional Slideout Divider Resize

## Context

The divider gesture currently assigns `slideoutWidth` and `contentWidth` on
every `onChanged` event. Both setters immediately invoke AppState callbacks
that write `Defaults[.previewWidth]` and `Defaults[.windowSize]`, so a 60–120 Hz
drag turns into repeated preferences I/O and notifications on the main thread.
The gesture's final assignment does not undo that work.

## Invariants

1. The divider remains visually live while dragging, with the same 200-point
   minimum for each column and the same left/right direction.
2. Drag updates perform no persistence callback.
3. A completed drag invokes each persistence callback exactly once with the
   final rounded width.
4. Window-edge live resize, preview open/close geometry, popup height, and image
   row sizing do not change.
5. `SlideoutView` owns only gesture delivery; width math and transaction state
   belong to `SlideoutController`.

## Selected design

`SlideoutController.updateDividerResize(translation:totalWidth:)` captures the
slideout width on the first update of a drag. Every update derives from that
stable base plus the gesture's cumulative translation, applies placement-aware
direction and both width floors, and writes the controller's observable backing
widths directly. Direct backing writes update SwiftUI layout without invoking
the persistence callbacks exposed by the committed property setters.

`finishDividerResize()` closes the transaction, clears its captured base, and
invokes the slideout/content callbacks once each. Calling finish without a
started transaction is a no-op. The existing `startResize`/`endResize` methods
remain dedicated to NSWindow edge resizing.

## Alternatives rejected

- Debounce preference writes. It still writes during long drags and requires a
  timer/flush contract at gesture end.
- Reuse `resizingMode` and the geometry-reader widths. That state deliberately
  switches columns into flexible layout for NSWindow edge resizing; the
  divider requires two fixed widths and would create a layout-feedback seam.
- Move Defaults throttling into AppState. That spreads one gesture transaction
  across the view, controller, and composition root instead of fixing ownership.

## Verification

A controller test sends two cumulative updates, proves callbacks remain empty
while the observable widths change, then proves finish publishes each final
width once. A second finish proves idempotence. The full macOS 26 ARM workflow
is the compile, lint, unit, UI, and performance gate.

## Evidence

- RED run `29298677929` passed project generation and strict lint, then every
  shard repeated only the expected missing `updateDividerResize` and
  `finishDividerResize` test-target compile errors.
- GREEN run `29298867332` passed project generation, strict lint/build, all 390
  unit tests, both UI shards, and text/image performance shards on its first
  attempt.
- Diff review confirms `SlideoutView.onChanged` crosses no committed width
  setter or persistence callback, cumulative translation uses the captured
  first-frame base, finish is idempotent, and NSWindow edge resize is unchanged.
