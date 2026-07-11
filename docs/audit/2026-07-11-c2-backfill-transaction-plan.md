# C2.3 Fingerprint backfill transaction plan

**Goal:** Ensure lazy fingerprint backfill belongs to the ingest transaction that discovered it and cannot be committed by a later unrelated ingest after the original commit fails.

**Findings:** `NEW-ingest-dualpath-2` and `NEW-dedup-ids-3`. `findDuplicate` currently mutates candidate contents as a read side effect before `commit`; a thrown save leaves those changes pending on the long-lived actor context, and the next successful save can persist them.

**Design:** Make duplicate search return the duplicate plus candidate models that need backfill, without mutating them. Apply those idempotent backfills inside `commit`'s transaction, excluding the duplicate that is about to be deleted. On any commit error, explicitly `rollback()` the actor context before returning the failure result. A DEBUG-only forced commit failure immediately before save provides deterministic regression coverage for pending-change leakage.

## Invariants

- Authoritative `supersedes` behavior and post-hash byte equality remain unchanged.
- Backfill still occurs for surviving candidates on a successful ingest and stays idempotent.
- The duplicate and size-trim delete plus new insert remain one save/transaction.
- A failed ingest emits no event, does not update the index, and leaves no pending insert/delete/backfill for the next ingest.
- No `@Model` crosses actor isolation; the duplicate-search result is actor-internal only.
- The failure seam is DEBUG-only.

## TDD and verification

1. Seed a pre-migration-style large row with a nil fingerprint. Force a superset ingest to fail immediately before save, then run an unrelated successful ingest. Assert the seed remains nil; on current code it is incorrectly committed by the second save.
2. Capture the expected runner red, then move backfill mutation into `commit` and rollback on failure.
3. Re-run the existing successful-backfill/idempotence tests and the full strict lint/unit/UI/performance matrix.
4. Record evidence and close C2.3 without broadening into C3 search consolidation.

## Files and commits

- Modify: `Maccy/Ingest/ClipboardIngestor.swift`
- Modify: `MaccyTests/FingerprintMigrationTests.swift`
- Later evidence: `docs/audit/2026-07-10-master-roadmap.md`, `docs/audit/INDEX.md`

- `test(c2.3): expose cross-ingest backfill commit`
- `fix(c2.3): bind fingerprint backfill to its ingest transaction`
- `docs(c2.3): record backfill transaction evidence`
