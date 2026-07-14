# Incremental Thumbnail Disk Maintenance

## Context

The code-quality review confirms two costs in the thumbnail miss path:

- `ThumbnailCache` inventories and stats the complete thumbnail directory after
  every successful PNG write, making a cold burst O(N x M) on its serialized
  actor;
- cancellation is checked before entering `ImageProcessor`, but not after the
  synchronous downsample, so a superseded row can still encode, write, and
  inventory a thumbnail that its caller will discard.

## Invariants

1. `ThumbnailCache.thumbnail` and `evict` keep their caller-facing interfaces
   and memory/disk key semantics.
2. Existing disk contents are counted lazily on the first successful write.
   Constructing the cache and serving disk hits perform no directory inventory,
   so application startup gains no new work.
3. After that first inventory, successful writes and removals update an actor-
   owned byte ledger in O(1). A new inventory is requested only when the ledger
   exceeds the 256 MiB soft budget or becomes unknown after an unmeasurable
   mutation.
4. Over-budget inventory retains the existing modification-date LRU policy and
   subtracts bytes only for successful removals.
5. Cancellation observed after downsampling returns `nil` before PNG encoding,
   disk mutation, eviction, or memory-cache publication.
6. Main-list image geometry and preview/window geometry are out of scope and do
   not change.

## Selected design

`ThumbnailDiskUsageLedger` is a small value module owned exclusively by the
`ThumbnailCache` actor. Its interface accepts completed writes, removals, and a
fresh inventory total and returns only whether an inventory is required. It
knows byte-accounting policy but nothing about `FileManager`, URLs, images, or
actors.

`ThumbnailCache` remains the deep module at the existing seam. It owns the file
system implementation: measure a replaced file, finalize the PNG, measure the
new file, feed the ledger, and call one `inventoryAndEvictIfNeeded` operation
only when requested. That operation both establishes the authoritative total
and reuses its one set of entries for LRU eviction.

The cache initializer gains an internal downsample closure with the production
ImageIO implementation as its default. This is an internal test seam, not a new
caller responsibility. A test adapter can cancel its child task immediately
after returning a real downsampled image, deterministically exercising the
post-decode checkpoint.

## Alternatives rejected

- Scan every fixed number of writes. It leaves the budget knowingly exceeded
  for an arbitrary interval and still performs unnecessary periodic work.
- Dispatch inventory/eviction outside the actor. Concurrent file deletion and
  writes would give up the cache's current single-owner disk invariant.
- Inventory during cache construction. Even off-main I/O would add launch-time
  contention solely for housekeeping, contrary to the startup constraint.
- Persist a sidecar counter. Crash consistency and sidecar recovery add more
  failure modes than this soft cache budget warrants.

## Verification

TDD adds ledger tests for unknown, under-budget, over-budget, and removal
transitions, plus a cache integration test proving cancellation after a real
downsample leaves the disk directory empty. Existing miss/write, disk-hit,
explicit-evict, and per-size-key tests remain the behavior regression suite.

The macOS 26 ARM workflow is the only compile, lint, and test gate. The RED
commit intentionally names the desired internal interfaces before production
implementation; the GREEN commit must pass the complete matrix.
