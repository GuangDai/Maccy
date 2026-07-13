# Popup Runtime Services Design

## Context

`Popup` is owned by `AppState`, but its event handlers currently reacquire that
owner through `AppState.shared` and reacquire history through `History.shared`.
The 13 global reaches make the child depend on the process-wide composition
root, prevent isolated state-machine tests, and create a circular ownership
shape: `AppState` owns `Popup`, while `Popup` reaches back to the global
`AppState`.

The approved direction is a narrow runtime-services value configured by the
owner after `AppState` finishes constructing its mutually dependent popup,
preview, and navigation objects.

## Goals

- Remove every `AppState.shared` and `History.shared` reference from
  `Popup.swift`.
- Preserve popup opening, closing, sizing, hotkey cycling, shortcut selection,
  prewarming, and selection-commit behavior.
- Make Popup's outward effects directly injectable and observable in unit
  tests.
- Keep application wiring in `AppState`, the existing composition owner.
- Avoid exposing `History`, `NavigationManager`, `SlideoutController`,
  `AppDelegate`, or `FloatingPanel` as Popup dependencies.

## Non-goals

- Changing popup appearance, hotkeys, selection semantics, or timing.
- Redesigning `AppState`, `NavigationManager`, or the panel API.
- Closing the separate `History`/`Clipboard` dependency cycle.
- Introducing a general event bus or service locator.

## Architecture

Add an `@MainActor` `PopupRuntimeServices` value beside `Popup`. It contains
only high-level operations and queries required by the popup state machine:

- select the initial history item;
- open, close, query, and resize the panel;
- report whether an active preview selection requires the preview height floor;
- prewarm the visible history window;
- select a pressed shortcut item and report whether one was handled;
- highlight the next item while cycling;
- commit the current selection.

The services use closures rather than a `PopupHost` protocol. This keeps the
interface expressed in Popup's vocabulary and prevents a weak host reference
from growing into a proxy for all of `AppState`.

`Popup` starts with inert services so it can be constructed before the rest of
`AppState`. At the end of `AppState.init`, after `preview` and `navigator` are
initialized, `AppState` calls `popup.configureRuntimeServices(...)`. The live
closures capture `AppState` weakly and resolve concrete collaborators only for
the duration of each call. This avoids replacing the global reach with a new
strong ownership cycle through navigator/preview callbacks. No production path
reads a global singleton from `Popup`.

The local NSEvent monitor captures its own Popup instance weakly and calls
`shouldConsumeFlagsChanged` on that instance. It no longer finds the instance
through `AppState.shared.popup`.

## Operation Mapping

| Current global reach | Runtime-service operation |
| --- | --- |
| Select first unpinned/pinned item | `selectInitialItem()` |
| Panel open/close/isPresented/resize | `openPanel`, `closePanel`, `isPanelPresented`, `resizePanel` |
| Preview-open plus lead-selection query | `requiresPreviewMinimumHeight()` |
| AppState history prewarm | `prewarmVisibleWindow()` |
| Pressed shortcut lookup plus select/copy | `selectPressedShortcut() -> Bool` |
| Navigation cycle | `highlightNext()` |
| Commit selected item/footer/query | `commitSelection()` |

The pressed-shortcut operation is intentionally atomic at this boundary. Popup
only needs to know whether the shortcut was handled; it does not need the
`HistoryItemDecorator`, History, or Navigator objects involved.

## Data and Control Flow

1. `AppState` constructs `Popup` with inert services.
2. `AppState` constructs `SlideoutController` and `NavigationManager` using the
   existing relationships.
3. `AppState` installs live `PopupRuntimeServices`.
4. A hotkey or local event enters Popup's state machine.
5. Popup performs state transitions locally and invokes a runtime operation for
   each outward effect.
6. AppState-owned closures coordinate the concrete panel, history, navigator,
   and preview objects.

There is no new asynchronous transport. Existing `Task { @MainActor ... }`
deferral is retained only where current behavior relies on it.

## Failure Handling

The current live behavior treats an unavailable `appDelegate.panel` as a
no-op and considers the panel closed. The injected operations preserve that
behavior. `PopupRuntimeServices.inert` is also a no-op implementation for
isolated construction and tests. No new thrown errors or persistence paths are
introduced.

## Testing

Use TDD with a recorder-backed runtime-services instance.

- RED: opening selects the initial item and requests the panel open through the
  injected services.
- RED: close, closed-state query, resize, preview height floor, prewarm, cycling,
  shortcut handling, and commit-selection use the injected operations.
- RED: shortcut handling stops the cycle/toggle path when the service reports a
  handled shortcut.
- GREEN: wire the minimal service calls and preserve current state transitions.
- Structural gate: `rg 'AppState\.shared|History\.shared' Maccy/Observables/Popup.swift`
  returns no matches.
- Existing Popup, AppState, UI, and performance tests remain green in the full
  macOS 26 ARM CI matrix.

## Acceptance Criteria

1. `Popup.swift` contains no `AppState.shared` or `History.shared` reference.
2. Popup's constructor/configuration surface mentions no concrete AppState,
   History, navigation, preview, app delegate, or panel type.
3. Every current outward behavior has a focused injected-service test.
4. Existing user-visible popup and hotkey behavior is unchanged.
5. Generated Xcode project verification, strict lint/build, unit, UI, and
   performance shards all pass.
