# 14 — Module: Views (SwiftUI Interface)

**Directory:** `Maccy/Views/*` (~28 Swift) + `FloatingPanel.swift`  
**Baseline:** HEAD `6cd37c8`

---

## 1. Logical tree

```text
FloatingPanel
  └─ ContentView
       ├─ load task / KeyHandlingView
       ├─ Header / SearchField / Toolbar
       ├─ HistoryListView (rows, pins, footer)
       ├─ Slideout / Preview
       └─ PasteStack views …
```

---

## 2. Boundary rules (actual)

| Should | Does |
|--------|------|
| Bind `@Observable` | Mostly |
| No business rules | Mostly; Defaults/height details OK |
| No SwiftData writes | Yes |

`ContentView` uses `AppState.shared` and `try? history.load()` (DS-023).

---

## 3. Data flow

```text
History.items → list
decorator state → row / highlights
NavigationManager.scrollTarget → scroll
SlideoutController → preview
KeyHandling → AppState/History actions
```

Animation on `history.items` intentionally kept for frame spreading (comment in ContentView).

---

## 4. Concerns

| Topic | Note |
|-------|------|
| LazyVStack layout feedback | Historically fixed; keep fixed row geometry / hover discipline |
| Dual preview renderers | SwiftUI Text vs NSTextView |
| Viewport appear | VisibilityTracker + ensureThumbnail |
| shared AppState | testability |

---

## 5. Recommendations

Keep views thin. No new filter/dedup in views. Preview changes follow BS-5 glossary.

**Depth note:** Not every view modifier was line-audited; interface-layer role confidence **High**, per-file polish **Medium**.
