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
