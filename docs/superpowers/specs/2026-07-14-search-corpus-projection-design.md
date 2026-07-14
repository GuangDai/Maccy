# Actor-Owned Search Corpus Projection

## Context

`HistorySearchSession.corpusEntry(for:)` currently executes
`String(searchText.prefix(cap))` for every history item on the main actor. A
full load/reconcile or body-limit change therefore allocates up to N x cap body
copies before the SearchActor operation can even be enqueued. The actor already
owns matching and the long-lived corpus, but not the expensive projection that
creates that corpus.

## Invariants

1. `HistoryItem` and `HistoryItemDecorator` remain main-actor-only; only
   Sendable values cross to SearchActor.
2. The main actor performs no explicit substring materialization or body
   truncation when replacing/inserting corpus entries.
3. SearchActor clamps the supplied body limit through `TextLimits`, creates the
   capped body off-main, and stores only that capped string long-term.
4. The full source body is a transient Swift `String` COW value captured until
   the serialized actor update consumes it; no duplicate persistent column,
   startup scan, fetch, or permanently full-body actor corpus is introduced.
5. Search ordering, body-limit behavior, highlighting offsets, incremental
   insert/remove, and query semantics remain unchanged.

## Selected design

Add `SearchCorpusSource`, a Sendable value containing id, title, and the full
search body snapshot read on main. It deliberately has no cap operation.

The `HistorySearchBackend` corpus mutation interface accepts sources plus one
body limit captured for that operation:

```swift
func replaceCorpus(_ sources: [SearchCorpusSource], bodyLimit: Int) async
func insert(_ source: SearchCorpusSource, bodyLimit: Int, at position: Int) async
```

`HistorySearchSession` gains an injected main-actor `bodyLimitProvider`, matching
its existing mode provider. It builds source DTOs with direct String value
assignment and hands the same captured limit to the backend.

`SearchActor` is the only production adapter. Inside its isolation it clamps
the limit, materializes `String(source.body.prefix(limit))`, converts to the
existing `SearchCorpusItem`, and stores that capped item in `corpusByID`. The
pure search interface remains based on `SearchCorpusItem`; only the stateful
mutation interface changes.

## Alternatives rejected

- Persist another capped-body column. It duplicates data, needs migration and
  update rules, and a configurable cap would invalidate stored projections.
- Store full bodies in SearchActor and truncate per query. That increases the
  long-lived corpus and repeats work on every keystroke.
- Truncate every body once to the 256k maximum at ingest. It permanently pays
  the largest memory/storage cost even when the configured limit is 32k/1k.
- Read SwiftData models in a detached task. `@Model` cannot cross actor
  isolation and doing so would violate the repository's two-domain rule.

## Failure handling

Corpus updates retain the existing serialized task chain. If a body limit is
out of range, SearchActor clamps it before allocation. COW source values are
released after the queued operation completes; the actor dictionary receives
only capped `SearchCorpusItem`s.

## Verification

- A session/backend contract test proves the backend receives the full source
  body and the captured limit, rather than a main-capped body.
- An actor ownership test places a marker just beyond the minimum cap and proves
  the stateful actor corpus cannot match it, while a marker inside the cap does.
- Existing search semantics, corpus ordering, highlight, and text performance
  suites remain the regression/performance gate in the full macOS 26 ARM CI.
