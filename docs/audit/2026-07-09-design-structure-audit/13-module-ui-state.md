# 13 — Module: UI State (Popup / Navigation / Slideout / Footer / Memory / PasteStack)

**Directory:** `Maccy/Observables/*` excluding History/Decorator deep dives  
**Baseline:** HEAD `6cd37c8`

---

## 1. Popup

- Open/close, height, `needsResize`, test hotkey hooks  
- Written heavily from History (DS-007)  
- FloatingPanel owns NSPanel chrome  

**Target:** History emits resize **requests** via port; Popup owns chrome.

---

## 2. NavigationManager

### State

- `Selection<HistoryItemDecorator>`  
- leadHistoryItem / scrollTarget  
- keyboard vs hover  
- multi-select flags  

### Side effects on lead change

- Cancel previous lead’s preview generation  
- `AppState.shared.preview.scheduleRetarget`  

### Design notes

- Construct-injected History/Footer — good  
- Still touches AppState.shared.preview — medium  
- Hover must not set scrollTarget (layout feedback fix) — correct, well commented  

---

## 3. SlideoutController

Preview open/close animation, previewedItem, widths in Defaults, auto-open suppression. Cohesion medium–high.

---

## 4. Footer / FooterItem

Bottom actions (Clear…), confirmation, AppState.select branch.

---

## 5. PasteStack (+ History+PasteStack)

Ordered multi-paste; interrupted by external copy via Clipboard→History; interacts with navigation lead. Three-party coupling (Clipboard/History/Nav).

---

## 6. Memory governance

```text
VisibilityTracker.shared  // viewport UUID set
MemoryGovernor.shared
  attach(HistoryRef)
  DispatchSource memory pressure on main queue
  → releaseTransientImages on non-visible + ApplicationImageCache.purge
ReleaseReason enum
```

History decoupled via `HistoryRef` — good narrow protocol.  
DecodedImageCache **removed** intentionally on HEAD.

---

## 7. Findings

DS-007, DS-006, DS-028 (`multiSelectionEnabled = false`), PasteStack triangle.

---

## 8. Recommendations

Keep separate types (do not fold into History). Introduce UIEffectPort. Resolve multi-select dead switch.

**Confidence:** High.
