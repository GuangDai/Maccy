# 05 — Module: HistoryItemDecorator

**File:** `Maccy/Observables/HistoryItemDecorator.swift` (**554 LOC**)  
**Baseline:** HEAD `6cd37c8` · Flow G in `02`

---

## 1. Responsibility

**Declared:** Main-actor row VM — title, highlights, shortcuts, lazy thumbnail/preview.  
**Actual:** Above + app icon + visibility hooks + text preview cache + recursive observation of pin/title (`withObservationTracking`) + Perf hooks + preview body highlight state + pin toggle helper.

**Verdict:** Acceptable “row presentation aggregate” but near max size; must not absorb search/dedup.

---

## 2. Identity

```text
let id = UUID()   // new every init
== / hash by id only (nonisolated)
private(set) var item: HistoryItem  // holds @Model
```

Merge/recreate → new id → search corpus must drop old id (History handles).

---

## 3. Data flows

### 3.1 Text

```text
item.title → decorator.title (init + synchronizeItemTitle)
search apply → highlight / attributedTitle
item.previewableTextPrefix → text (lazy, Defaults limit)
item.searchText → needsScrollablePreview
setPreviewHighlight → previewAttributedText + ranges
```

### 3.2 Images

```text
ensureThumbnail/Preview
  → lazy imageData: first access faults item.imageData (blob/file)
  → Task @MainActor: await imageProcessor.*(data, size)
  → if !isInvalidated: publish NSImage
onDisappear → releaseTransientImages(.scrollOut) keeps thumbnail
invalidate/memory/settings → heavy release + clear caches
cancelPreviewGeneration → cancel task, keep cached previewImage
```

NavigationManager lead change cancels prior preview generation (correct serial ImageProcessor hygiene).

### 3.3 Observation sync (BS-7 related)

`synchronizeItemPin` / `synchronizeItemTitle` use `withObservationTracking` + re-arm on main — recursive observation pattern; roadmap noted 7.13 concerns. Risk: work amplification on model churn.

---

## 4. Dependencies

- `HistoryItem` (content coupling)  
- `ImageProcessing` (injectable; default process singleton)  
- `ApplicationImageCache.shared`  
- `Defaults` (sizes)  
- Visibility protocols  
- PerfRecorder DEBUG  

---

## 5. Findings / risks

| Issue | Detail |
|-------|--------|
| Holds live `@Model` | Lifecycle tied to mainContext; must `invalidate` on remove |
| `HistoryItem.image` still exists | Main-thread decode trap if called; list path uses processor |
| Global default processor | OK for cache sharing; tests can inject |

---

## 6. Target boundary

Keep as **sole row projection**. Do not add search engine or persistence. Optional future: split PreviewModel if file grows further.

---

## 7. Verification

- [ ] invalidate then ensure* does not fault torn model  
- [ ] scrollOut keeps thumbnail, drops preview  
- [ ] lead change cancels in-flight preview  

**Confidence:** High.
