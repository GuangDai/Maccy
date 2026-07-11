# 01 — Project Structure

**Baseline:** HEAD `6cd37c8`

---

## 1. Repository top level

```text
Maccy/                 Application sources (~120 Swift files)
MaccyTests/            Unit/integration + Support/ + Fixtures/
MaccyUITests/          UI / render perf
docs/audit/            Architecture, memory, roadmap, THIS suite
Designs/               Design assets (non-code)
scripts/               packaging
.github/workflows/     CI (macOS 26 ARM)
Maccy.xcodeproj
AGENTS.md / CLAUDE.md / README.md
```

Judgment: **repo-level** layout is clear. Debt is **inside `Maccy/`**.

---

## 2. Physical layout under `Maccy/`

### 2.1 Clear packages

| Directory | Role | Approx. files | Cohesion |
|-----------|------|---------------|----------|
| `Ingest/` | Actor, DTO, filter, signature index, pasteboard source | 5 | High |
| `ImageProcessing/` | Downsample, processor, thumbnail cache | 4 | High |
| `Models/` | SwiftData `@Model` | 2 | Medium (models overloaded) |
| `Engine/` | Title/signature/body pure helpers | 1 | High |
| `Core/` | `ClipboardDataProcessor` | 1 | High |
| `Processor/` | C++/ObjC++ + xxHash | few | High |
| `Persistence/` | Background context + VisibleWindowLoader | 1 | Medium (dead path colocated) |
| `Observables/` | Main-actor state | 11 | Mixed — History dominates |
| `Views/` | SwiftUI | ~28 | Medium–high |
| `Settings/` | Preferences UI | 9+ | High UI, config bus |
| `Intents/` | App Intents | 6 | High coupling to AppState |
| `Extensions/` | Defaults keys, AppKit helpers | ~21 | Utility bin |
| `Perf/` | Recording/fixtures | 2 | Isolated |

### 2.2 Root-level overload (~29 Swift files)

Mixed concerns at package root:

| Category | Examples |
|----------|----------|
| Composition | `AppDelegate`, `MaccyApp`, `Storage`, `Clipboard` |
| Search | `Search`, `SearchActor`, `SearchDTOs`, `SearchVisibility`, `TextLimits` |
| Sorting / actions | `Sorter`, `HistoryItemAction`, `Selection`, `PasteStack`, `KeyChord` |
| Cross-cutting | `Notifier`, `SoftwareUpdater`, `FloatingPanel`, `ApplicationImage*` |

**Problem:** Entry points, domain, and infrastructure are not discoverable by path alone. Search is root-level while history is under Observables.

### 2.3 Depth

- Not too deep (Settings ignore subfolder is fine).
- **Too flat** at root and partly in Observables.

### 2.4 Localizations

Many `*.lproj` next to code — product requirement; increases noise when browsing.

---

## 3. Logical architecture (analysis only — do not mass-move yet)

```text
Maccy system
├── Interface
│   ├── Views / FloatingPanel
│   ├── Settings
│   ├── Intents
│   └── Clipboard (in/out pasteboard adapter)
├── Application
│   ├── AppDelegate / AppState (composition + use-case entry)
│   ├── History (orchestration — OVERLOADED)
│   ├── NavigationManager / Popup / SlideoutController / Footer
│   └── Search orchestration (inside History)
├── Domain (partially explicit)
│   ├── HistoryItemEngine
│   ├── IngestFilter + SignatureIndex rules
│   ├── Sorter / TextLimits / HistoryItemAction
│   └── Model field meanings (bound to SwiftData)
├── Infrastructure
│   ├── Storage + SwiftData
│   ├── BackgroundClipboardIngestor (@ModelActor)
│   ├── SearchActor / ImageProcessor
│   ├── Processor C++
│   └── Notifier / Updater / Accessibility
└── Shared
    ├── Extensions / Defaults keys
    └── Sendable DTO catalog (Ingest/Dtos)
```

**Pseudo-layering risk:** Runtime dependencies jump layers via `*.shared` (see `16`).

---

## 4. Entry-point map

| Entry | Symbol | Discoverable? |
|-------|--------|----------------|
| Process | `MaccyApp` + `AppDelegate` | Yes |
| Pasteboard poll | `Clipboard.start` from AppDelegate | Yes |
| History state | `History.shared` / `AppState.shared.history` | Yes but overloaded |
| Persistence | `Storage.shared` | Yes |
| Live ingest truth | `BackgroundClipboardIngestor` | Yes if you know `Ingest/` |
| Search truth | `SearchActor` **and** residual `Search` | **Easy to confuse** |

---

## 5. Scattered / mixed concerns

| Phenomenon | Detail |
|------------|--------|
| Filter rules | Clipboard private sets + IngestFilter + hardcoded `ingestConfig` UTIs |
| Search | Root dual engines |
| Signatures | DTO vs Engine |
| UI state | Observables mixes History, chrome, memory |
| Persistence API | `HistoryPersistence` + direct `Storage.shared` in same type |

---

## 6. Extensibility

| Helps | Hurts |
|-------|-------|
| Actor packages evolve independently | New features default to `History` + `shared` |
| DTO boundary | Dual paths double test cost |
| Support test doubles | Intents/Views bypass ports |

---

## 7. Recommendations (structure only)

1. Prefer **logical packages** over one giant `git mv`.  
2. Keep new files out of root.  
3. Split structure PRs from behavior PRs.  
4. Candidate packages later: `Search/`, `Composition/`, `Application/`.  

See playbook Wave E for ordering.

> **E2 resolution (2026-07-12):** `2a06a58` colocated the four search sources under `Maccy/Search/`; `72fa8f2` + `9e54d77` formed `Maccy/Application/` around the app entry, delegate, composition root, and DEBUG hooks. Root-level Swift files fell from the verified baseline of 29 to 22 without behavior changes; XcodeGen output and the full generated-project matrix/package passed in `29167115880`.
