# Search state invalidation design

## Context

The 2026-07-13 code-quality review identified two active state-consistency
defects around `HistorySearchSession`:

- `D5-replacecorpus-no-invalidation`: `replaceCorpus` swaps the complete
  id-to-decorator lookup and queues a backend corpus replacement without
  invalidating a search already running against the old corpus.
- `VF-04-select-unknown-noop`: `HistoryMutations.select` invalidates the current
  search before classifying modifiers, then returns for `.unknown`, leaving the
  query populated but its result task cancelled.

Current production call ordering masks D5, but the public session operation does
not enforce its own staleness invariant. VF-04 is reachable when an unmapped
modifier chord activates an item during an in-flight search.

## Goals

- Make complete corpus replacement invalidate the previous search generation
  at the operation boundary.
- Make an unknown modifier activation a true no-op, including preserving the
  current search generation.
- Preserve all known copy/paste action mappings and query-clearing behavior.
- Add no fetch, startup work, actor hop, or UI/image behavior.

## Selected design

`HistorySearchSession.replaceCorpus` calls its existing `invalidate()` before
changing `decoratorsByID` or queuing the actor update. The session therefore
owns the invariant that no result computed from the replaced corpus can apply,
independent of caller sequencing.

`HistoryMutations.select` captures the modifier flags and resolves
`HistoryItemAction` first. A non-empty flag set resolving to `.unknown` returns
before invalidation or clipboard/UI effects. Known actions and the no-modifier
default path invalidate exactly as before.

## Alternatives rejected

- Rely on every `replaceCorpus` caller to immediately call `refresh`. This is
  the current implicit precondition and leaves the module contract fragile.
- Re-run search from the unknown-modifier branch. The action is defined as a
  no-op; preserving the already-running work is both cheaper and clearer.
- Invalidate every incremental corpus insert/remove. Those operations are not
  required to close the two verified findings and would broaden behavioral
  scope unnecessarily.

## Verification

TDD first adds synchronous contract assertions:

1. `replaceCorpus` increments the session generation.
2. `.unknown` selection leaves the generation unchanged.

The RED commit must fail only those assertions. The GREEN commit then receives
one macOS 26 ARM full-matrix workflow; no local Xcode commands are run.
