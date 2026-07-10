# C2.2 Dedup signature single-source plan

**Goal:** Remove the unmaintained parity invariant between `snapshot(of:)` and `BackgroundClipboardIngestor.findDuplicate` by deriving `SignatureDTO` entries in exactly one helper, with no dedup behavior change.

**Finding:** `NEW-dedup-ids-2`. Index registration uses entries constructed in `snapshot(of:)`; candidate lookup independently reconstructs the same type/fingerprint/size shape. Any later drift silently converts matching candidates into misses.

**Design:** Extract `signatureDTO(of:)` beside the DTO projection functions. Make `snapshot(of:)` call it, and make `findDuplicate` pass its `.entries` to `SignatureIndex`. Keep the separate `HistoryItemEngine.Signature` used by authoritative `candidate.supersedes` unchanged because it carries actual bytes and transient-type containment semantics.

## TDD and verification

1. Add a DTO test requiring `signatureDTO(of:)` and asserting it is the exact signature carried by `snapshot(of:)`, including small and fingerprinted large entries. Capture the expected compile-red on the macOS runner.
2. Extract the helper and replace the inline candidate-entry map with `signatureDTO(of: item).entries`.
3. Run strict lint, unit, UI, and performance shards; existing containment/dedup integration tests remain the behavioral parity gate.
4. Record evidence and mark `NEW-dedup-ids-2` complete without touching C2.3 fingerprint-backfill persistence.

## Files and commits

- Modify: `Maccy/Ingest/Dtos.swift`
- Modify: `Maccy/Ingest/ClipboardIngestor.swift`
- Modify: `MaccyTests/DtoTests.swift`
- Later evidence: `docs/audit/2026-07-10-master-roadmap.md`, `docs/audit/INDEX.md`

- `test(c2.2): require one dedup signature projection`
- `refactor(c2.2): reuse the DTO signature for candidate lookup`
- `docs(c2.2): record signature single-source evidence`
