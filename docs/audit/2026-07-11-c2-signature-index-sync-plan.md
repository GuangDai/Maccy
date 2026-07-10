# C2.1 SignatureIndex UI-deletion synchronization plan

**Goal:** Keep `BackgroundClipboardIngestor`'s in-memory dedup index synchronized after successful main-actor `History.delete`, `History.clear`, and `History.clearAll` mutations, without changing user-visible history behavior or adding a store fetch to the ingest hot path.

**Finding:** C2 / DS-009. The ingest actor maintains its index for deletions performed by its own commit, but UI-driven store deletions never reach that actor. Correctness currently self-heals through the authoritative `supersedes` confirmation; the defect is unbounded stale candidate and bridge-map retention.

**Design:** Extend `ClipboardIngestor` with one batched async `synchronizeStoreEvents(_:)` method. `History` captures stable `ItemID`s before deleting models, and only after persistence succeeds submits one batch: `.removed` for the deleted unpinned/single items or `.cleared` for a full clear. `BackgroundClipboardIngestor` applies those events to both `SignatureIndex` and `persistentIDByItemID`; the legacy main-actor adapter explicitly no-ops because it owns no index. The actor hop is asynchronous after the committed store mutation, so UI methods remain synchronous.

## Invariants

- No event is emitted when persistence throws.
- `clear()` removes only unpinned IDs; pinned candidates remain indexed.
- `clearAll()` resets both index maps and leaves the next ingest able to rebuild from the committed store.
- One UI operation creates at most one synchronization task/actor hop.
- `HistoryItem` models never cross actors; only existing Sendable `StoreEvent`/`ItemID` values do.
- The production ingest commit and its single transaction remain unchanged.

## TDD execution

1. Add spy-backed async tests proving successful single delete, unpinned clear, and full clear forward the exact events. Push the test-only commit and capture the expected runner failure before production wiring exists.
2. Add a background-ingestor test proving `.removed` eliminates a registered dedup candidate before the next ingest.
3. Add the protocol method, explicit adapter implementation, actor index/bridge application, and the three `History` call sites. Keep the implementation minimal.
4. Run the focused/unit runner gate, then the full macOS 26 ARM CI. Inspect job status first and log tails only for failed jobs.
5. Record run evidence and mark C2.1 complete in the live roadmap/index. Treat `NEW-dedup-ids-2` signature re-derivation and `NEW-dedup-ids-3` lazy-backfill mutation as separate later small steps.

## Files

- Modify: `Maccy/Ingest/ClipboardIngestor.swift`
- Modify: `Maccy/Observables/History.swift`
- Modify: `MaccyTests/Support/IngestorSpy.swift`
- Modify: `MaccyTests/HistoryTests.swift`
- Modify: `MaccyTests/BackgroundClipboardIngestorTests.swift`
- Later evidence: `docs/audit/2026-07-10-master-roadmap.md`, `docs/audit/INDEX.md`

## Commit sequence

- `test(c2.1): define UI deletion index synchronization`
- `fix(c2.1): synchronize dedup index after UI deletions`
- `docs(c2.1): record signature-index synchronization evidence`
