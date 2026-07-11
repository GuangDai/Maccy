# 03 — Module: Composition Root (AppDelegate / AppState / Singletons)

**Baseline:** HEAD `6cd37c8`  
**Files:** `AppDelegate.swift` (390), `AppState.swift` (228), `MaccyApp.swift`, singleton owners

---

## 1. Declared vs actual

| Type | Declared | Actual |
|------|----------|--------|
| `MaccyApp` | SwiftUI app entry | Hosts AppDelegate adapter |
| `AppDelegate` | Launch wiring | Wiring **+** status item **+** Defaults migration **+** hotkey disable **+** DEBUG UITest/Perf distributed notifications **+** terminate cleanup |
| `AppState` | Top observable | Holds History/Footer/Popup/Navigator/Preview; select/pin/prewarm/settings window |

---

## 2. Startup data flow (ordered)

### 2.1 `applicationWillFinishLaunching`

| Step | Action | Evidence |
|------|--------|----------|
| 1 | Disable Sparkle under testing | AppDelegate ~60–67 |
| 2 | `AppState.shared.appDelegate = self` | Reverse reference for panel |
| 3 | Construct `BackgroundClipboardIngestor(container: Storage.shared.container, image: defaultImageProcessor, now: Date, onEvent: History.shared.consume)` | 82–87 |
| 4 | `Clipboard.shared.ingestor = …`; `start()` | 88 |
| 5 | Defaults listeners: clipboard interval, status bar, icon, ignore, enabled types | 90–135 |
| 6 | `synchronizeMenuIconText` recursive `withObservationTracking` | 245–258 |

### 2.2 `applicationDidFinishLaunching`

| Step | Action |
|------|--------|
| 1 | `migrateUserDefaults` (1.x→2.x key inversions) |
| 2 | `disableUnusedGlobalHotkeys` |
| 3 | Build `FloatingPanel { ContentView() }`, `onClose → popup.reset` |
| 4 | `MemoryGovernor.shared.attach(History.shared); start()` |
| 5 | DEBUG: UITest / Perf hooks |

### 2.3 Terminate

Perf dump; optional `history.clear()` on quit.

---

## 3. AppState API surface

| API | Side effects |
|-----|----------------|
| `select()` | paste stack / history.select / footer / copy query string |
| `togglePin()` | multi pin with transaction wrapper |
| `prewarmVisibleWindow()` | `try? history.load()` — **swallows errors (DS-023)** |
| `menuIconText` | reads first unpinned decorator text |
| Settings | lazy controller; close observer to release panes |

`ContentView` holds `@State private var appState = AppState.shared` — global session as view state.

---

## 4. Coupling

```text
AppDelegate → Storage, Clipboard, History, AppState, ImageProcessor, MemoryGovernor, FloatingPanel
AppState → History (ctor), Footer, Popup, NavigationManager, SlideoutController, Clipboard.shared
History → AppState.shared (23 sites)  // reverse
Intents/Views → AppState.shared
```

**Service-locator pattern** rather than pure composition root: many modules reach into `shared` after launch.

---

## 5. Findings

| ID | Issue |
|----|--------|
| DS-006 | Singleton bus |
| DS-007 | History↔AppState |
| DS-018 | Intents → shared |
| DS-023 | prewarm/load try? |
| DS-026 | AppDelegate multi-role |
| DS-032 | DEBUG hooks inflate production type |

---

## 6. Target boundary

```text
CompositionRoot
  builds Storage, ImageProcessor, Ingestor, History, AppState, Clipboard, MemoryGovernor
  starts timers, pressure source
AppDelegate: NSApplicationDelegate only
AppState: UI session + gesture use-cases (no infrastructure details)
DebugHooks: separate type, DEBUG only
```

`onEvent` should be `StoreEventSink` protocol, not hard-coded `History.shared`.

---

## 7. Testability

| Good | Bad |
|------|-----|
| `AppState.init(history:footer:)` injectable | Production always `AppState.shared` |
| UITest via DistributedNotification works | Bloats AppDelegate |

---

## 8. Verification

- [ ] List all AppDelegate responsibilities; none belong to Delegate after split  
- [ ] `onEvent` injectable  
- [ ] Intent tests without full AppState.shared  

**Confidence:** High on wiring path and coupling counts.

> **E2 resolution (2026-07-12):** `9e54d77` introduced a lazily initialized concrete `Application/CompositionRoot.swift` for Intent/ingest/clipboard/memory wiring and moved the delegate/entry under `Application/`; `72fa8f2` moved the complete test/perf notification lifecycle into whole-file DEBUG `DebugHooks.swift`. `AppDelegate` fell to 209 lines. Remaining singleton-default replacement is tracked separately by E5/DS-006.
