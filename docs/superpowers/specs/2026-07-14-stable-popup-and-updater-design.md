# Stable Popup Presentation and Deferred Updater

## Context

Three presentation/runtime side effects currently escape their owning feature:

- opening the lateral preview recomputes the panel's vertical height, so a short
  popup jumps to the configured preview floor;
- the footer treats a partial modifier subset as the clear-all chord, so the
  default `Shift-Command-C` popup shortcut temporarily swaps Clear to Clear All;
- opening General settings starts Sparkle even when automatic checks are off.

## Invariants

1. Opening or closing the lateral preview changes width only. The current panel
   height remains owned by the main popup/list layout, and preview images stay
   aspect-fit inside that stable height.
2. The footer swaps Clear for Clear All only when the pressed device-independent
   modifiers exactly equal the clear-all shortcut modifiers.
3. Sparkle is created without starting its updater. It starts once, and only
   when automatic checks are enabled or the user explicitly requests a check.

## Ownership

- `SlideoutController` owns lateral preview geometry and no longer asks Popup
  for a vertical height during a horizontal toggle.
- `Footer` owns the pure clear-action modifier classification used by the view.
- `SoftwareUpdater` owns a small idempotent start gate around Sparkle.

These changes add no startup work and do not change main-list image row sizing.

## Verification

- A window-backed slideout test asserts that preview toggling preserves height
  even when an injected preferred height differs.
- A pure footer test supplies the popup shortcut modifiers and asserts Clear
  remains selected; the exact clear-all chord still selects Clear All.
- An injected updater-start closure proves disabled initialization performs no
  start, while enabling automatic checks and manual checks start at most once.
- The GitHub macOS ARM workflow is the build, lint, and test gate.
