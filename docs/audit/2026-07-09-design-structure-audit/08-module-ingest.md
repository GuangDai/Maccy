# 08 — Module: Ingest Subsystem

**Directory:** `Maccy/Ingest/`  
**Baseline:** HEAD `6cd37c8` · Flow A in `02` is the step bible for this module

---

## 1. Components

| File | Types | Role |
|------|-------|------|
| `ClipboardIngestor.swift` | protocol, `MainActorIngestorAdapter`, `BackgroundClipboardIngestor` | Contract + impls |
| `Dtos.swift` | ContentDTO, StoreEvent, snapshot, StoredItemID, … | Sendable catalog |
| `IngestFilter.swift` | IngestConfig, filterContents | Pure filter |
| `PasteboardSource.swift` | protocol, NSPasteboardSource | Snapshot |
| `SignatureIndex.swift` | index struct | Dedup candidates |

**Judgment:** Highest-cohesion subsystem in the app. Debt is at **seams** (MainActor hop, dual config, index vs UI deletes, adapter).

---

## 2. Protocol

```text
protocol ClipboardIngestor: Sendable {
  func ingest(_ request: IngestRequest) async -> IngestResult
}
```

Minimal and correct.

### MainActorIngestorAdapter (DS-016)

```text
MainActor.run {
  History.shared.add(historyItem(from: request))
  return IngestResult(event: nil, metrics: .zero)
}
```

Not production-wired. Different semantics (no StoreEvent). Isolate to tests.

---

## 3. BackgroundClipboardIngestor — internal state machine

```text
State:
  signatureIndex, persistentIDByStoredID, dedupIndexInitialized
  image: ImageProcessing   // injected; main ingest path does not decode for title
  now, onEvent
  modelContext via @ModelActor
```

Step sequence: **see `02` A.7–A.13** (do not duplicate full tables here).

### Single-transaction invariant

`commit` one `transaction` + `save`. Failures log; no index maintain.

### Index lifecycle

| When | Action |
|------|--------|
| First ingest | Full fetch register O(n) |
| After successful commit | unregister deleted; register inserted |
| After failed commit | index unchanged (matches DB) |
| After UI delete | **index unchanged (DS-009)** |

Stale id → `model(for:)` shell → supersedes false → skip (safety). Index can bloat.

### Fingerprint backfill

`backfillMissingFingerprints` on **candidates only**. Not full-table migration. Older “8.5 completely missing” claims are **partially outdated**.

### Parity gap

No sessionLog modification merge — documented intentional.

---

## 4. Dtos deep notes

### StoredItemID (DS-019 — resolved `1393143`)

The index now keys directly on Apple's stable, `Hashable`/`Sendable` `PersistentIdentifier.ID`. The old `String(describing: persistentModelID)` → double-FNV → UUID projection and its latent format/collision risk were deleted without adding a schema column.

### snapshot(of:) cost

May parse rich text preview and touch `imageData` after commit — hot-path cost awareness.

### IngestPlan (DS-017)

Enum exists; **not** used to drive decisions. Only Sendable test.

---

## 5. IngestFilter

> **Current update (D2, `a487276`):** `Clipboard` attaches `IngestPolicy` to
> each request. The pure overload accepts the rich-text presence decision and
> runs on the ingest actor. `IngestMainActorPlan` requests main work only when
> small RTF/HTML parsing is reachable; ordinary file/plain/image copies do not
> enter `MainActor`.

High-cohesion pure function. RTF/HTML via NSAttributedString. Regex uncached (correct over Clipboard dead cached path).  
At the audit baseline production wrapped the whole operation in MainActor.run because of AppKit affinity + Defaults.

---

## 6. SignatureIndex

Four maps: signature↔id, entry↔ids.  
API: lookup, candidates(forEntries:), register, remove, merge(StoreEvent).  
Background path uses register/remove manually, not `merge(StoreEvent)`.

Complexity: O(entries × hits) candidate generation; supersedes is authority.

---

## 7. Dependencies

```text
Clipboard → IngestRequest → BackgroundClipboardIngestor
                ↑ PasteboardSource
Ingestor → filterContents(IngestConfig)
        → SignatureIndex
        → HistoryItem on actor context
        → onEvent → History.consume
```

Unsound: Adapter → History.shared.  
Improve: single rule source for UTIs.

---

## 8. Tests (strength)

ClipboardIngestorTests, BackgroundClipboardIngestorTests, IngestFilterTests, SignatureIndexTests, DtoTests, DtoRoundTrip, IngestErrorPropagation, SendableBoundary — **strong**.

---

## 9. Recommendations

1. Keep package.  
2. Isolate adapter.  
3. Unify UTI/config constants.  
4. Sync index on UI delete (or rebuild).  
5. Delete or use IngestPlan.  
6. Engine inputs as DTO (DS-030).  

**Confidence:** High.
