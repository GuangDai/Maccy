# C6 stored-item identity study and plan

**Goal:** Close DS-019 and sharpen DS-005 by replacing the undocumented `String(describing: persistentModelID)` → double-FNV → UUID projection with a documented identity that remains `Hashable` and `Sendable`, without adding a schema column that has no product consumer.

## Evidence and decision

Apple documents [`PersistentIdentifier.id`](https://developer.apple.com/documentation/swiftdata/persistentidentifier/id-swift.property) as the value that uniquely identifies a model within its containing store and [`PersistentIdentifier.ID`](https://developer.apple.com/documentation/swiftdata/persistentidentifier/id-swift.struct) as the stable identity of a SwiftData model. The ID is `Equatable`, `Hashable`, and `Sendable`, which are exactly the dedup index and actor-event requirements.

Current call-path audit:

- The derived UUID is not stored by either `@Model` and has no external/cross-process consumer.
- `BackgroundClipboardIngestor` rebuilds the index from committed rows once per process and keeps a separate ID → fetchable `PersistentIdentifier` bridge.
- Production derives IDs only for committed rows: initial index rows, post-save inserted rows, duplicates/trim victims inside a transaction over previously committed rows, and main-side delete/clear of stored decorators.
- Search uses `HistoryItemDecorator.id`, an unrelated presentation UUID; content dedup uses xxh3 fingerprints, also unrelated.

Decision: use `PersistentIdentifier.ID` directly as `StoredItemID`. Do not add a UUID column. A stored column would require migration/backfill and a second source of identity while adding no capability; keeping the string fold retains an undocumented format dependency and collision surface despite Apple already exposing the required stable value.

This decision is deliberately recorded here rather than as an ADR: the representation is internal, has no persisted/external contract, and is straightforward to reverse, so it does not meet the repository's hard-to-reverse ADR threshold.

## Design

1. Rename the generic `ItemID` vocabulary to `StoredItemID` and project it as `item.persistentModelID.id`.
2. Make `SignatureIndex` generic over any `Hashable & Sendable` identity. Production specializes it to `StoredItemID`; pure index tests continue to use UUID fixtures.
3. Remove the index's unused snapshot/event convenience initializers and their tests. Actor synchronization already owns real `StoreEvent` integration; keeping a second, test-only event adapter is a shallow duplicate interface.
4. Characterize that a committed snapshot carries the model's exact stored identity, then run the full CI matrix.

## Invariants

- No index key is derived before the corresponding production model has a permanent, committed identity.
- `ItemSnapshotDTO.id`, `StoreEvent.removed`, the signature index, and the persistent-ID bridge use the same `StoredItemID` type.
- `PersistentIdentifier` remains in the snapshot for `model(for:)`; its `.id` is correlation identity, not a fetch handle.
- Search presentation IDs and content fingerprints remain distinct and unchanged.
- No schema/model migration and no user-visible behavior change.

## TDD and verification

1. Add a committed-model test asserting `snapshot(of: item).id == item.persistentModelID.id`; capture the current UUID/type mismatch red.
2. Implement the direct identity projection, generic index, vocabulary rename, and dead adapter deletion.
3. Run focused/full unit, UI, performance, strict lint, generated-project zero-drift, and Release gates through the macOS runner.
4. Update the roadmap, verification matrix, existing identifier glossaries, and this record with evidence.
