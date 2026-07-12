# D3 — Lossless ingest mailbox

Date: 2026-07-12

## Decision

Use a FIFO mailbox with one drain task, not latest-wins coalescing.

Maccy is a clipboard history: once a pasteboard snapshot has been observed,
silently discarding an intermediate distinct copy violates the product's core
behavior. The current one-unstructured-Task-per-change implementation preserves
payloads but has no backpressure and does not make submission order structural.
The mailbox keeps both properties that matter:

- every observed `IngestRequest` is delivered exactly once, in FIFO order;
- only one `ingest` call is outstanding, and one drain Task serves the burst.

This coalesces task creation, not user data. It also makes persistence-failure
surfacing part of the same ordered drain.

## TDD

1. Submit three requests to an ingestor that suspends the first call.
2. Assert only the first request reaches the ingestor while it is suspended.
3. Release it; assert all three requests arrive in change-count order.
4. Wire `Clipboard.checkForChangesInPasteboard()` through the mailbox and retain
   the existing single-dispatch and failure-surfacing tests.

## Scope

No bounded/drop policy is added. At the 500 ms poll cadence, a FIFO queue is
already bounded by observed pasteboard changes in practice; inventing a cap
would reintroduce an implicit data-loss decision.

## Result

- `IngestMailbox` owns an O(n) indexed FIFO drain (no `removeFirst()` shifts).
- `Clipboard` submits the captured request, ingestor, and main-actor result
  callback; failure surfacing therefore remains ordered with ingest completion.
- The blocking-actor test proves requests 2 and 3 do not enter a reentrant actor
  while request 1 is suspended, then proves delivery order `[1, 2, 3]` after
  release.
- Implementation: `b754ac6`; generated Xcode project artifact: `9fbb6e6`.
- Verification: generation/zero drift, strict SwiftLint/build, unit, both UI
  shards, perf-text, and perf-image all green in `29175614620`.
