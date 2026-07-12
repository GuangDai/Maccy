# D1 — Startup/load A/B gate

Date: 2026-07-12

## Question

With the complete retained history and search semantics unchanged, is a
store-sorted, size-bounded fetch faster than the current full fetch followed by
Swift sorting and decoration on main?

This is a startup/first-popup performance decision, not a memory decision. The
06-27 memory captures already proved that windowing `all` has approximately no
memory value (SwiftData blobs stay pinned) and degrades UX by making search miss
items. That design is rejected.

## Throwaway prototype

Run both load cores against the same in-memory 200-long-text store:

- A/current: unbounded `FetchDescriptor` → `Sorter.sort` → decorate all.
- B/candidate: SQLite-sorted pinned + unpinned queries, unpinned capped to the
  configured retained size → concatenate by pin position → decorate all.

Warm both paths, alternate measurement order to reduce cache/order bias, and
emit parseable average milliseconds. The prototype lives temporarily in the
existing perf-text test target because this machine has no macOS toolchain; it
is deleted after the CI measurement.

## Gate

- Implement only if B is materially faster and returns the entire retained
  history in the exact pin/sort order.
- If B is slower, equal within noise, or needs partial-history/search behavior,
  do not ship it. Record the no-go and delete the obsolete test-only
  `VisibleWindowLoader` scaffolding instead of leaving a misleading future path.
