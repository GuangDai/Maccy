# 07 — Module: Clipboard

**File:** `Maccy/Clipboard.swift` (**416 LOC**)  
**Baseline:** HEAD `6cd37c8` · Flows A, D in `02`

---

## 1. Declared vs actual

**Declared:** Observe system pasteboard; dispatch to off-main ingest.  
**Actual:**

1. Timer poll + changeCount gates  
2. Fast ignore (types/apps/user flags)  
3. Snapshot → IngestRequest  
4. **Write** history item / string to pasteboard  
5. **Synthetic paste** (CGEvent)  
6. clear system clipboard  
7. Chrome RD / NetBeans focus sync  
8. **Dead** private helpers for item regex/empty/rich  

**Verdict:** Too many roles — **split candidate** (Monitor / Writer / PasteService).

---

## 2. Inbound (Flow A.0–A.6)

See `02` for step table. Key evidence:

- Timer: `start()` ~71–79  
- Gates: `checkForChangesInPasteboard` ~197–237  
- Request build: `ingestRequestFromPasteboard` ~252–273  
- Dispatch: `Task { await ingestor.ingest(request) }`  

**Dead code confirmation (DS-008):**

| Symbol | Line (approx) | Callers |
|--------|---------------|---------|
| `shouldIgnore(_ item: NSPasteboardItem)` | 315 | **none** |
| `isEmptyString` | 346 | **none** |
| `richText` | 359 | **none** |
| `shouldIgnore(_ types:)` | 296 | used 221 |
| `shouldIgnore(_ sourceAppBundle:)` | 306 | used 225 |

---

## 3. Outbound (Flow D)

`copy(HistoryItem)` reads `@Model.contents` on main — appropriate. Marks `.fromMaccy` and `.source`. Triggers re-check → re-ingest cycle.

`paste()`: Accessibility check + CGEvent with layout-aware keycode (QWERTY switch cases).

---

## 4. Dual rules with IngestFilter

| Rule | Clipboard | IngestFilter |
|------|-----------|--------------|
| enabled/ignored types | shouldIgnore(types) | shouldIgnoreTypes |
| apps | shouldIgnore(bundle) | shouldIgnoreApplication |
| dyn/ole/Word | filteredTypes (private; not all used on live path) | filteredTypeSet |
| regex / empty / rich | **dead helpers** | **live** in filterContents |
| supported set | private let | **hardcoded in ingestConfig** |

Authoritative filter is actor-side. Fast path is approximate early-out.

---

## 5. Findings

DS-008, DS-020, DS-024, DS-006 (AppState interrupt), self-ingest cycle documentation.

---

## 6. Target types

```text
PasteboardMonitor   // timer, changeCount, snapshot → IngestRequest
PasteboardWriter    // copy item/string, markers
PasteService        // CGEvent paste + Accessibility
```

Shared: `PasteboardSource` protocol (already exists).

---

## 7. Verification

- [ ] Delete dead helpers; CI  
- [ ] Single UTI constant source vs ingestConfig  
- [ ] Timer tolerance experiment  

**Confidence:** High on dead helpers and dual config.
