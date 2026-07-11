# C2.3 Fingerprint backfill transaction plan

**Goal:** Remove lazy fingerprint backfill from duplicate search and prove it is atomic with the ingest transaction that discovered it.

**Findings:** `NEW-ingest-dualpath-2` is confirmed: `findDuplicate` mutates candidate contents as a read side effect. The proposed `NEW-dedup-ids-3` cross-ingest timing is **refuted**: Apple documents that [`ModelContext.transaction(block:)`](https://developer.apple.com/documentation/swiftdata/modelcontext/transaction%28block%3A%29) writes pending changes when its closure finishes, so backfill did not wait for the later explicit `save()` as the verification assumed.

**Design:** Make duplicate search return the duplicate plus candidate models that need backfill, without mutating them. Apply those idempotent backfills inside `commit`'s transaction, excluding the duplicate that is about to be deleted. On any transaction error, explicitly `rollback()` the actor context before returning the failure result. A DEBUG-only failure thrown inside the transaction closure provides deterministic atomicity coverage.

## Invariants

- Authoritative `supersedes` behavior and post-hash byte equality remain unchanged.
- Backfill still occurs for surviving candidates on a successful ingest and stays idempotent.
- The duplicate and size-trim delete plus new insert remain one save/transaction.
- A failed ingest emits no event, does not update the index, and leaves no pending insert/delete/backfill for the next ingest.
- No `@Model` crosses actor isolation; the duplicate-search result is actor-internal only.
- The failure seam is DEBUG-only.

## TDD and verification

1. Seed a pre-migration-style large row with a nil fingerprint. Force a superset ingest transaction to throw, then run an unrelated successful ingest. Read through a fresh context and assert the seed remains nil.
2. Capture the missing-seam compile red, then move backfill mutation into the transaction and rollback on failure.
3. Re-run the existing successful-backfill/idempotence tests and the full strict lint/unit/UI/performance matrix.
4. Record evidence and close C2.3 without broadening into C3 search consolidation.

## Files and commits

- Modify: `Maccy/Ingest/ClipboardIngestor.swift`
- Modify: `MaccyTests/FingerprintMigrationTests.swift`
- Later evidence: `docs/audit/2026-07-10-master-roadmap.md`, `docs/audit/INDEX.md`

- `test(c2.3): expose cross-ingest backfill commit`
- `fix(c2.3): bind fingerprint backfill to its ingest transaction`
- `docs(c2.3): record backfill transaction evidence`

## Completion evidence and corrected mechanism (2026-07-11)

C2.3 is complete at `f9f0e85`/`ba00696`; the final runner proof is `f9f0e85` plus the fresh-context test commit already in branch history.

- [Red run 29136425890](https://github.com/GuangDai/Maccy/actions/runs/29136425890) passed strict SwiftLint and failed only because the new `setCommitFailureForTesting` seam did not exist.
- Early iterations deliberately exposed two incorrect assumptions instead of hiding them: run 29136555814 showed that throwing *after* `transaction` was already after persistence; run 29136739033 enforced Swift 6 by rejecting a mutable non-Sendable journal captured by the transaction closure. Runs 29136821626/29136934917 then separated main-context cache visibility from actual store persistence.
- Apple’s transaction contract explains the evidence: a successful closure writes pending changes. The final forced error is therefore thrown **inside** that closure. `findDuplicate` is now read-only, `commit` applies surviving-candidate backfills inside the same transaction as trim/delete/insert, and the catch path calls `rollback()`.
- The regression test reads from a fresh `ModelContext` after a later unrelated successful ingest, proving the failed transaction did not persist the nil-column backfill. The existing successful-backfill and idempotence tests remain green.
- [Final green run 29137114873](https://github.com/GuangDai/Maccy/actions/runs/29137114873) passed strict SwiftLint, unit, `ui-1`, `ui-2`, `perf-text`, and `perf-image`. The expected forced-error log has a narrow CI allowlist keyed to `ForcedCommitFailure`.

Result: `NEW-ingest-dualpath-2` is fixed; `NEW-dedup-ids-3` is closed as a refuted timing claim with the underlying read/write coupling still removed.
