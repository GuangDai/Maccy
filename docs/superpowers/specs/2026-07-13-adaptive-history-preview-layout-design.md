# Adaptive History Rows and Preview Layout

## Context

Maccy's list currently forces every row to `Popup.itemHeight` (22/24 pt) and
then forces thumbnails to `Popup.itemHeight - 10`. As a result, the existing
`imageMaxHeight` setting changes decode size but cannot change the displayed
thumbnail height. Text is always one line. The fixed geometry prevents
asynchronously arriving thumbnails from resizing rows, but it also makes the
appearance controls misleading.

The preview has two related problems. A fixed 150 pt window-height floor is too
small once the metadata block is included, and the AppKit text view is not
explicitly constrained to the preview viewport width. Its intrinsic text width
can therefore influence layout and make the vertical scrollbar appear beside
the longest line rather than at the preview column's trailing edge.

This design changes the sizing rules without adding a large settings surface or
allowing asynchronous content to mutate row geometry.

## Goals

- Make the existing image-height setting control displayed thumbnail size.
- Let text rows show a configurable number of lines.
- Allow image and text rows to have different heights without thumbnail-arrival
  reflow.
- Keep popup height predictable when rows have different heights.
- Give an open preview a configurable height floor related to the main popup's
  configured maximum height.
- Make preview text wrap to the viewport and keep its vertical scrollbar at the
  preview column's trailing edge.
- Keep the settings change to two new compact numeric controls.

## Non-goals

- No free-form per-row resize, density presets, or separate image/text modes.
- No vertical window-resize behavior change.
- No image aspect-fill/cropping; thumbnails remain aspect-fit.
- No redesign of preview metadata, colors, typography, or pane width.
- No eager classification or decoding of the entire history collection.

## Approaches considered

### 1. Content-adaptive, stable rows (selected)

Text and image rows use separate deterministic height rules. A realized image
row establishes its semantic kind before thumbnail generation completes, so
the placeholder and final thumbnail occupy the same reserved row. This makes
the current image-height control honest, keeps compact text rows compact, and
does not make every row as tall as the largest content type.

### 2. One uniform configurable row height

This preserves the simplest height cap, but making the default 40 pt thumbnail
visible would expand every text and footer row to roughly 50 pt. It wastes most
of the list for text-heavy histories and couples two independent preferences.

### 3. Fully intrinsic row heights

Letting SwiftUI size every row from its loaded content is visually flexible,
but asynchronous image arrival changes the `LazyVStack` geometry and recreates
the layout-feedback problem the fixed row height was introduced to prevent.
It also makes `maxVisibleItems` unstable during scrolling.

## Row layout model

Introduce a small pure `HistoryRowLayout` value namespace. It owns geometry
only and has no model, image-processing, or view dependency.

- `baseHeight`: the existing platform floor (22 pt before macOS 26, 24 pt on
  macOS 26+).
- `verticalInsets`: 10 pt total, preserving the current 5 pt top/bottom image
  padding.
- `textLineIncrement`: one system-body line increment for every configured line
  after the first.
- `textHeight(lines:)`: `baseHeight + (clampedLines - 1) * lineIncrement`, with
  lines clamped to 1...4.
- `imageHeight(maxImageHeight:)`: `max(baseHeight, clampedImageHeight +
  verticalInsets)`.
- Footer rows remain `baseHeight`; only history content rows are adaptive.

`HistoryItemView` asks its already-realized decorator whether the item has image
content. This uses the same lazy blob cache that thumbnail generation will use
immediately on appearance; it does not walk or classify the complete history.
The semantic image/non-image decision is cached separately from decoded image
state, so memory cleanup can drop bytes without changing row height.

`ListItemView` receives an explicit row height and image-content height. The
placeholder/title fallback and final thumbnail share that row height. The
thumbnail stays aspect-fit and is bounded by `imageMaxHeight`; text uses
`textRowLines` for both plain and attributed titles.

## Popup height semantics

Variable image rows must not force eager model inspection merely to calculate a
count-based cap. `maxVisibleItems` therefore remains a compact-row viewport cap:

```
maximum scroll height = maxVisibleItems * configured text row height
```

A text-only list still shows at most the configured number of rows. Larger
image rows consume more of that viewport and may result in fewer simultaneously
visible image items, which is preferable to shrinking the configured images.
The measured content height still wins when the list is shorter than the cap.
Pinned sections continue to be measured outside the scroll viewport as today.

The old `Popup.itemHeight` remains the compact platform height for headers and
footer rows. List capping switches to `HistoryRowLayout.textHeight`.

## Preview height model

Add `previewMinimumHeightPercent`, clamped to 25...100 with a default of 60.
The floor is derived from `Defaults.windowSize.height`, the same configured
maximum that governs the main popup:

```
preview floor = window maximum height * percentage / 100
target height = min(window maximum height,
                    max(main natural height, preview floor))
```

When the preview is closed, only the main natural height applies. When it is
open, a short result list can no longer collapse the preview to an unusable
strip, while a naturally taller main list remains authoritative. A percentage
avoids contradictory pixel settings and scales with the user's existing popup
height.

The Popup runtime port continues to expose only
`requiresPreviewMinimumHeight`; Popup owns the pure Defaults-backed height
policy, while AppState owns the live preview/selection predicate.

## Preview text layout

Both short and long text paths fill the preview body's available rectangle.

For `PreviewTextRep`:

- the `NSScrollView` has a vertical scroller and no horizontal scroller;
- the `NSTextView` is vertically resizable but not horizontally resizable;
- its autoresizing mask tracks the scroll view width;
- its text container tracks the text-view width and uses word wrapping;
- the representable fills the SwiftUI column in both dimensions.

For the SwiftUI short-text path, use a vertical-only `ScrollView`, give its text
content the full available width with leading alignment, and give the scroll
view the full preview-body rectangle.

`PreviewItemView` gives the preview body layout priority and keeps the existing
metadata block below it. Thus the metadata remains visible, and all remaining
height belongs to the scrollable image/text body.

## Settings

Appearance settings retain `imageMaxHeight` and add:

- `textRowLines` (1...4, default 1)
- `previewMinimumHeightPercent` (25...100, default 60)

Only the English source-locale keys are added, following the repository's
existing source-string workflow; translated locale files remain Weblate-owned.
No picker or mode switch is introduced.

## Data flow and ownership

Defaults are read at the rendering/pure-policy boundary:

- `HistoryRowLayout` receives explicit values in tests and views.
- `ListItemView` receives resolved geometry rather than reaching into History.
- `Popup` resolves the preview percentage against `windowSize`.
- `AppState` only reports whether the preview floor is currently applicable.

No model crosses an actor boundary. No new singleton reach is introduced. Row
kind remains a main-domain presentation fact and image decode remains on the
existing actor.

## Testing

1. Pure row-layout tests cover line clamping, image-height clamping, different
   text/image heights, and the compact-row viewport cap.
2. List view tests or structural assertions verify both plain and attributed
   titles receive the configured line limit and image rows reserve geometry
   before decoded image publication.
3. Popup tests cover 25/60/100 percent preview floors, main-height dominance,
   and window-maximum clamping through the injected runtime port.
4. AppKit preview tests verify no horizontal scroller, width tracking,
   vertical resizing, word wrapping, and a vertical scroller.
5. Existing thumbnail/decorator tests continue to prove the requested decode
   size and cleanup behavior.
6. The macOS ARM workflow is the only build/lint/test gate.

## Compatibility and failure behavior

Existing users keep one-line text rows. Their existing image-height value starts
controlling display geometry as its label already promises. Invalid persisted
values are clamped at the policy boundary, so malformed Defaults cannot create
zero-height rows or a preview larger than the popup maximum. If an image decode
fails, its reserved image row stays stable and continues showing the existing
fallback rather than collapsing.
