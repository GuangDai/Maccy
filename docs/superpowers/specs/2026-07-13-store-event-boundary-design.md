# Store-event boundary hardening design

## Context

Clipboard ingestion is serialized by `IngestMailbox`, but successful main-side
delete and clear operations currently call
`ClipboardIngestor.synchronizeStoreEvents(_:)` from an unrelated fire-and-forget
task. A delete can therefore commit before the ingest actor removes the same
item from its dedup index, while a newly observed copy overtakes that removal.

The same boundary also contains a dependency cycle: the live `History` factory
reaches `Clipboard.shared`, while `Clipboard` writes ingest failures directly to
`History.shared.lastPersistError`. Separately, `deleteAll()` batch-deletes only
`HistoryItem`; store-level batch deletes do not provide a reliable child-row
cascade for `HistoryItemContent`.

## Goals

- Give pasteboard ingests and main-side store events one FIFO order.
- Preserve every observed copy and every committed delete/clear event.
- Remove the `Clipboard -> History.shared` dependency.
- Make clear-all remove both history items and their content rows, including
  changes that were pending when the command began.
- Keep all actor boundaries DTO-only and preserve current user-visible behavior.

## Non-goals

- Do not change ingest coalescing, dedup semantics, or history ordering.
- Do not add per-candidate persistence fetches to the copy hot path.
- Do not migrate legacy `searchText` rows in this batch.
- Do not remove the remaining production `History -> Clipboard` adapter; that
  direction is the application command boundary and is no longer a cycle once
  the reverse edge is removed.

## Chosen design

### One mailbox, two operation kinds

`IngestMailbox` will own a private FIFO of operations:

- ingest an `IngestRequest`, then deliver its `IngestResult` completion;
- synchronize a non-empty `[StoreEvent]` batch to the same ingestor.

Both public submission methods are main-actor isolated. One drain task processes
the array by index and awaits each actor call before advancing. Submission order
therefore becomes the total order: a committed delete submitted before a later
pasteboard observation reaches the actor first; an already-queued ingest remains
ahead of a later delete. No event or copy is coalesced away.

`Clipboard.synchronizeStoreEvents(_:)` will be the narrow application adapter.
It snapshots the currently configured ingestor and submits the batch through
the same mailbox used by `checkForChangesInPasteboard()`. The live
`HistoryRuntimeServices.publishStoreEvents` closure calls this adapter instead
of creating an unstructured task.

### Composition-owned ingest failure sink

`Clipboard` will store an inert-by-default main-actor error sink. Tests can
provide the sink at initialization; `CompositionRoot.prepareForLaunch` replaces
it with a closure that writes to the composed `History` instance. Clipboard
continues to translate `IngestResult.persistenceFailed` into its small local
error value, but it no longer names or fetches `History.shared`.

This keeps success and failure delivery separate at the leaf while making their
application ownership explicit at the composition boundary. A non-failure
result remains a no-op.

### Complete clear-all transaction

`SwiftDataHistoryPersistence.deleteAll()` will first save pending main-context
changes, matching `deleteUnpinned()`. It will then batch-delete
`HistoryItem` and `HistoryItemContent` inside one transaction, process pending
changes, and save once. Explicitly deleting both entities makes the store result
independent of relationship cascade behavior in in-memory versus SQLite stores.

## Data flow

```text
main delete/save -> History store-event sink
                 -> Clipboard.synchronizeStoreEvents
                 -> IngestMailbox FIFO
                 -> ClipboardIngestor.synchronizeStoreEvents

pasteboard change -> Clipboard request snapshot
                  -> same IngestMailbox FIFO
                  -> ClipboardIngestor.ingest
                  -> result completion
                  -> Clipboard failure sink
                  -> CompositionRoot-owned History instance
```

## Tests

- Extend the mailbox test double to suspend an ingest, enqueue a store event and
  another ingest, then assert the actor sees exactly that operation order.
- Verify `Clipboard.synchronizeStoreEvents(_:)` uses the configured ingestor and
  that an empty batch is ignored.
- Replace the singleton-coupled failure test with an instance sink assertion;
  verify only persistence failures invoke it.
- Verify the composition root wires a failure into the supplied `AppState`'s
  history rather than `History.shared` where practical through existing seams.
- Add a pending-insert clear-all test and retain the child-count assertion.
  Use a temporary SQLite-backed `Storage` test when needed to cover store-level
  batch behavior instead of relying only on the in-memory configuration.

## Risks and controls

- A generalized mailbox could accidentally drop completions or reorder work.
  A single sequence-recording actor test locks both properties.
- Reconfiguring the failure sink after launch could retain application state.
  The composition closure captures the composed history weakly.
- Saving pending changes before clear-all can surface a save error earlier.
  The persistence method already throws, and `HistoryMutations` already records
  the error without mutating its in-memory projection.

## Success criteria

- No fire-and-forget store-event synchronization remains in production wiring.
- `Clipboard.swift` contains no reference to `History.shared`.
- Mailbox tests prove mixed operations execute FIFO and losslessly.
- Clear-all leaves both model counts at zero for saved and pending rows.
- Generated-project, lint/build, unit, UI, and performance CI shards remain green.
