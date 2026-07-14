# Decisions

> Load-bearing architectural/UX decisions (ADR-style), current as of HEAD. One-line outcome + why. (Replaces the dated per-audit decision docs.)

## Two-domain isolation
Main (`@MainActor`) ↔ background actors communicate **only via Sendable value DTOs**; a `@Model` never crosses an actor boundary. *Why:* keeps the pasteboard/decode/search heavy work off-main without SwiftData isolation hazards; makes the UI seam testable with value substitutes.

## Swift 6 *complete* strict concurrency, zero escape hatches
`SWIFT_STRICT_CONCURRENCY = complete`; no `@unchecked Sendable` / `nonisolated(unsafe)` (every former escape hatch was removed by using actors or `OSAllocatedUnfairLock`). *Why:* the concurrency model is the architecture; an escape hatch would be a latent bug.

## xxh3 dedup fingerprint (supersedes FNV-1a)
`maccy::processor::xxh3_64` (vendored xxHash, fixed seed 0, 16 KiB threshold) is the live dedup hash, persisted in `HistoryItemContent.fingerprint` and lazily backfilled for legacy rows inside the ingest commit. FNV-1a is retained in C++ but not called. *Why:* faster, lower-collision dedup with a persistent column avoids re-hashing on read.

## SignatureIndex = per-entry containment + authoritative confirm
`SignatureIndex` generates O(hits) duplicate *candidates* by shared content entries; the caller confirms each with authoritative `dataLikelyEqual` (requires both fingerprints). *Why:* fast candidate generation with zero false-positive deletes.

## Search: off-main, no index, grapheme-correct
`SearchActor` runs the 4 modes over Sendable corpus values; **no trigram/index** (the no-index decision held — bottleneck is Fuse, and an index costs memory + breaks complete search); offsets are `Character`/grapheme (`String.distance`), never NSRange/UTF-16. *Why:* keeps the main thread under 16 ms/keystroke and emoji/CJK highlights correct.

## History facade split
`History` is a 368-LOC facade over `HistoryListState` / `HistoryMutations` / `HistoryStoreProjector` / `HistorySearchSession`. *Why:* locality — each collaborator owns one concern (list state / commands / store projection / search); the facade is the only thing views touch.

## Popup geometry: stable, drag-driven (candidate ①)
Height = `clamp(totalContent, floor, maxHeight)`; `maxHeight` = drag-persisted `windowSize.height`; `floor` = `previewMinimumHeightPercent × maxHeight`, **always-on**. Search drives filtering only, never geometry (it does not emit `.resizePopup`). `maxVisibleItems` removed; vertical drag enabled. *Why:* the popup must not bounce in size when searching; the user sets height by dragging.

## Memory: 100 MB is unreachable; floor ~62 MB
Framework (AppKit+SwiftUI+SwiftData) floor is ~62 MB; window-open ~110–130 MB is framework cost. The structural root cause (unbounded `fetchAll` + never-reset `mainContext`) persists; the only remaining lever is F1 (independent blob storage, image-heavy-only). *Why:* measurement (06-27 6 h dump + MallocStackLogging) proved reclamation can't reach 100 MB without removing framework cost or blob storage.

## Image cache: per-decorator coordinator, no shared decoded cache
`DecodedImageCache` was **deleted**; decoded images are owned per-decorator by `ImageGenerationCoordinator` (released on scroll-out/memory-warning) + the preview-size cap. *Why:* a retained shared cache increased memory; preview bitmaps aren't the lever.

## XcodeGen is the project owner
`project.yml` is the editable spec; the generated `Maccy.xcodeproj` is committed; CI + release regenerate twice and reject drift. *Why:* kills pbxproj merge conflicts and makes the project declarative/auditable.

## Crash safety: `queue:.main` + lock-based deinit
`ApplicationImage`'s dispatch source uses `queue:.main` (the `@MainActor` closure prologue would trap off-main); the source is held in a nonisolated `OSAllocatedUnfairLock` and `deinit` cancels via `withLock` (thread-safe) so background `NSCache` eviction can't trap. Zero `queue:.global()` repo-wide. *Why:* a latent SIGTRAP (watched bundle delete/rename) + its NSCache-eviction sibling were both real; both closed structurally.

## Preferences: one source of truth, `Defaults` library
All preferences declared once in `Defaults.Keys+Names.swift` (zero `@AppStorage`); panes bind via `@Default`. *Why:* avoids scattered defaults/drift. (Naming consolidation across ~40 controls is an open candidate ②.)
