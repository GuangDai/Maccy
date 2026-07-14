# Image Generation Coordinator Design

## Goal

Finish item 4 of the quality-review cleanup by moving one history row's image
generation lifecycle out of `HistoryItemDecorator`. The refactor must preserve
all user-visible behavior, especially stable main-window image-row geometry,
lazy image-blob loading, cancellation, and the existing preview/thumbnail caps.

## Chosen boundary

Add a main-actor `ImageGenerationCoordinator` under `Maccy/ImageProcessing/`.
One coordinator belongs to one decorator and owns:

- the injected `ImageProcessing` dependency;
- lazy loading and caching of the model's image bytes;
- thumbnail and preview task handles;
- the published thumbnail and preview images;
- invalidation, cancellation, and release policy;
- the shared generation pipeline and DEBUG performance recording.

`HistoryItemDecorator` remains the compatibility facade used by views,
navigation, memory governance, and tests. Its existing image properties and
methods forward to the coordinator. Consumers therefore do not gain a new
dependency, and no view or layout code needs to change.

The coordinator receives a main-actor image-data provider. Construction does
not call the provider, preserving the current no-eager-fault behavior. It owns
the invalidated state so a deleted model is never faulted after invalidation.

## Generation pipeline

Thumbnail and preview generation use one private operation selected by a small
kind enum. The operation performs the actor hop, invalidation guard, result
publication, and optional DEBUG timing exactly once. Only the processor method,
target size, destination image, and performance-recorder endpoint vary by kind.

The current target-size policy remains unchanged. The main-window thumbnail
height continues to come from `HistoryRowLayout.effectiveImageContentHeight`,
not source-image dimensions. Preview size remains capped by
`imageMaxPreviewPixels` and the popup screen. Compatibility accessors stay on
`HistoryItemDecorator` so existing views and settings documentation remain
valid.

## Release and text-cache behavior

The coordinator handles only image state. `HistoryItemDecorator` continues to
own and clear its text-preview cache for non-scroll release reasons. This keeps
the existing `releaseTransientImages` contract intact while preventing the new
module from acquiring text responsibilities.

`.scrollOut` cancels and drops preview state but keeps the thumbnail. Setting
changes, memory pressure, and invalidation cancel both tasks and clear both
images plus cached bytes. Explicit preview cancellation keeps an already
decoded preview, as today.

## Alternatives rejected

1. Extract only a generic private helper in `HistoryItemDecorator`. This removes
   duplicated lines but leaves the god-object and its image state intact.
2. Expose the coordinator directly to SwiftUI views. This extracts more surface
   immediately, but spreads a new dependency through layout code and creates
   avoidable Observation/UI churn.

The private-composition facade gives the cohesion improvement without changing
the UI dependency graph.

## Verification

Use TDD with coordinator-focused tests that first fail because the type is
absent. Cover lazy loading, one in-flight task per kind, preview cancellation,
release/reload, and invalidation preventing publication. Existing decorator,
memory-governance, UI, and performance tests must remain unchanged and green.

The generated Xcode project must register the new source and tests with zero
generation drift. The final gate is the complete macOS 26 ARM matrix.
