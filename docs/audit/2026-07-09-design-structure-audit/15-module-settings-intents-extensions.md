# 15 — Module: Settings / Intents / Extensions / Misc

**Baseline:** HEAD `6cd37c8`

---

## 1. Settings

Panes: General, Appearance, Storage, Ignore, Pins, Advanced.  
Direct `Defaults` read/write. Storage pane reads `Storage.shared.size` (DS-033).  
No domain logic ideal; Defaults become **implicit domain config bus**. History init listens to many `Defaults.updates` (temporal coupling).

---

## 2. Intents (DS-018)

| Intent | Behavior |
|--------|----------|
| Get / Select / Delete / Clear | Direct `AppState.shared.history` / navigator |
| HistoryItemAppEntity | Projection |
| AppIntentError | Errors |

**Recommendation:** `HistoryCommandService` protocol implemented by app; Intents depend on protocol only.

---

## 3. Extensions

Utility bin: Defaults.Keys, PasteboardType (fromMaccy…), String.shortened, Collection.surrounding, NSImage/NSScreen helpers.

### Collection+Surrounding (HEAD)

`item(before:)` **guards** `currentIndex > startIndex` before offset -1 — prior trap finding **fixed on HEAD**. Tests: `CollectionSurroundingTests`.

---

## 4. Other root types

| Type | Role | Note |
|------|------|------|
| Sorter / BinaryInsertion | Total order + log insert index | Clear; shared with incremental path |
| Selection | Multi-select structure | Sendable |
| KeyChord / KeyShortcut / KeyboardLayout | Key bindings | System coupling |
| Notifier | User notifications | |
| SoftwareUpdater | Sparkle | MainActor care |
| Accessibility | Paste permission | |
| Perf/* | Benchmarks | DEBUG paths |
| ItemsProtocol | HasVisibility / ItemsContainer | Navigation |

---

## 5. Recommendations

- Theme Extensions subfolders (Defaults / AppKit / String).  
- Port Intents.  
- Keep Sorter independent.  

**Confidence:** High on Intent coupling; High on surrounding fix.
