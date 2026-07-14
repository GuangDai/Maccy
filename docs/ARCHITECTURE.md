# Architecture

> Current as of HEAD (master). A clipboard-history manager: AppKit + SwiftUI + SwiftData, Swift 6 *complete* strict concurrency, macOS 14+. This is the detailed companion to `CLAUDE.md`; domain terms live in `CONTEXT.md`.

## Two-domain isolation

The data pipeline is split across two domains that communicate **only via Sendable value DTOs** — a `@Model` never crosses an actor boundary.

- **Main domain** (`@MainActor`) — SwiftUI views + `@Observable` view models (`AppState`, `History`, `Popup`, `SlideoutController`, `NavigationManager`, `HistoryItemDecorator`, `Footer`). `Storage` is `@MainActor`; `Storage.shared.context` is `container.mainContext` (Main only).
- **Background actors** (off-main) — `BackgroundClipboardIngestor` (`@ModelActor actor`; the bare name `ClipboardIngestor` is the Sendable *protocol*), `ImageProcessor`, `ThumbnailCache`, `SearchActor`. Views reference none of them; `@Observable`s hold them only behind Sendable protocols. Only Sendable DTOs cross (`StoreEvent`, `ItemSnapshotDTO`, `SearchMatchDTO`, `SearchCorpusSource`, `IngestRequest/Result`, `MaccyFingerprint`).

Swift 6 `complete` mode is set in all three xcconfigs with **zero** `@unchecked Sendable` / `nonisolated(unsafe)`.

## Module map (`Maccy/`)

| Area | Modules | Role |
|------|---------|------|
| Application | `Application/` (`AppDelegate`, `CompositionRoot`, `MaccyApp`) | status item, panel ownership, launch wiring, DI composition root |
| Views | `Views/` | SwiftUI popup tree (`ContentView`, `HistoryListView`, `HeaderView`, `SlideoutView`, `PreviewItemView`, `FooterView`, …) + modifiers |
| Observables | `Observables/` | `@MainActor @Observable` view models (`AppState`, `History` facade, `Popup`, `SlideoutController`, `NavigationManager`, `HistoryItemDecorator`, `Footer`) + `HistoryListState`/`HistoryMutations`/`HistoryStoreProjector` |
| Search | `Search/` | `SearchActor` (4 modes), `HistorySearchSession`, `RowHighlighter`, DTOs, mode enum |
| Ingest | `Ingest/` | `IngestMailbox`, `BackgroundClipboardIngestor`, `SignatureIndex`, DTOs |
| ImageProcessing | `ImageProcessing/` | `ImageProcessor`, `ThumbnailCache`, `ImageGenerationCoordinator`, `ImageDownsampler` |
| Engine | `Engine/` | `HistoryItemEngine` (dedup signature/fingerprint superset logic) |
| Core | `Core/` | `ClipboardDataProcessor` (xxh3 threshold, `dataLikelyEqual`) |
| Processor | `Processor/` (`C++/ObjC++`) | xxh3 + FNV-1a (xxHash vendored), UTF-8 validation, bridged via `MaccyTextProcessor` |
| Persistence | `Persistence/` (`PinService`) + `Observables/HistoryPersistence.swift` | SwiftData ports over a caller `ModelContext` |
| Models | `Models/` | `@Model HistoryItem`, `HistoryItemContent` (incl. `fingerprint UInt64?`, `searchText String?`) |
| Settings | `Settings/` | 6 panes (general/storage/appearance/pins/ignore/advanced) |
| Perf | `Perf/` | `PerfRecorder` (DEBUG-only timing) |

## Data flow

**Ingest (off-main, single transaction):** `Clipboard` (Main, Timer polls pasteboard) → `IngestMailbox` (Main, FIFO — one outstanding actor call) → `BackgroundClipboardIngestor.ingest`: filter → `SignatureIndex` dedup → size-trim (`fetchCount` + bounded `fetchLimit` tail fetch) → delete dup → insert → save → emit `StoreEvent`. `CompositionRoot` wires `onEvent = { history.consume(event, trimmedPersistentIDs:) }`.

**Reconcile (Main, 4.4a incremental):** `History.consume` → `HistoryStoreProjector.consume`. `.added/.merged` → `insertIncrementally` (`persistence.model(for: PersistentIdentifier)` + binary insert + drop trimmed decorators). `.removed/.cleared` or miss → full `reconcile()`.

**Search (off-main):** `HistorySearchSession` (Main: 200 ms debounce, corpus projection, staleness via monotonic generation) → `await SearchActor.search` → `[SearchMatchDTO]` → apply highlights + publish visible. Four modes (exact/fuzzy/regexp/mixed) with full-text body fallback; offsets are grapheme-correct (`String.distance`/`index(offsetBy:)`).

**Images (off-main decode):** `HistoryItemDecorator` → `ImageGenerationCoordinator` (Main) → `await ImageProcessor.thumbnail/preview` → `ThumbnailCache` (NSCache + disk-LRU).

## Value ports (the seams)

- **Inbound** `StoreEvent` (Sendable): actor → `History.consume`.
- **Outbound** `HistoryUIEffect` (`@MainActor`): `closePopup`/`resizePopup`/`select`/`highlightFirst`/`scrollTo`, drained via `HistoryUIEffectSink` into `AppState.applyHistoryUIEffect`. (`.resizePopup` is emitted on real content/geometry changes — load, pin/delete/clear, row-geometry default changes — **not** on search.)
- **DI ports** (value-typed, test-substitutable, but wired over singletons in `makeShared()`): `PopupRuntimeServices`, `FooterAction`, `HistoryItemDecoratorFactory`, `SlideoutController`, `HistoryRuntimeServices`/`HistoryClipboardActions`. `AppState.shared` is still the view hub (`ContentView: @State = AppState.shared`).

## Background context

The ingest actor owns its own isolated `ModelContext` via the `@ModelActor` macro + `DefaultSerialModelExecutor(ModelContext(container))`, taking `storage.container` directly. There is no `Storage.newBackgroundContext()`.

## Build / test

No local toolchain — CI (macOS 26 arm64, driven via `gh`) is the only gate. XcodeGen owns the project (`project.yml` → committed generated `Maccy.xcodeproj`); zero-drift gates in CI + release. Five shards: `unit`, `ui-1`, `ui-2`, `perf-image`, `perf-text` (perf is blocking). See `CLAUDE.md` for the operating workflow; key decisions in `DECISIONS.md`.
