# 2026-07-12 — History B2–B5 deep-module design

| Field | Value |
|-------|-------|
| **Status** | Approved by the user's direct instruction to start B2–B5, split `History` as far as sound, improve cohesion, and reduce coupling without further product decisions. |
| **Baseline** | `master` at `096db46`; `History.swift` = 979 lines. D4/D6, D1 no-go, E4 deletion, C1/C2/C5/C6, D2/D3, and DS-025/030/031 are already landed. |
| **Supersedes** | The sequencing-only “defer split” decision in `2026-07-10-history-split-plan/`. Its invariants, hollow-work test, B1 lesson, and red lines remain authoritative. |
| **Scope** | B2 file/type split, B3 test migration, B4 legacy writer deletion, B5 mutation-generation chokepoint, and the History→AppState inversion required to make the split reduce coupling rather than move it. |

## 1. Goals and proof

The work is complete only when:

1. Production and tests no longer call `History.add`; `MainActorIngestorAdapter`,
   `sessionLog`, and the legacy find/merge/insert family are deleted.
2. Every logical list/order replacement passes one mutation chokepoint that
   invalidates an in-flight search exactly once before stale results can apply.
3. `History` remains the stable `@MainActor @Observable` facade used by views,
   intents, AppState, and tests, but no longer implements persistence projection,
   search-session machinery, and mutation orchestration in one type.
4. Store IO used by History modules crosses the `HistoryPersistence` seam; no
   `Storage.shared.context` remains in `History.swift` or its extracted modules.
5. `History` and its modules contain no `AppState.shared` reference. UI actions
   cross a value-oriented `HistoryUIEffect` sink configured by `AppState`, so
   dependency direction is AppState → History, never a B1-style adapter → shared.
6. Public behavior, full-history search, pin ordering, decorator reuse, ingest
   trimmed-id handling, errors, and SwiftUI observation remain covered and CI-green.

This is a structure/correctness/testability milestone. It does not claim a
memory reduction and will not revive partial/windowed history.

## 2. Rejected approaches

### A. Extension-only file split

Moving methods to `History+Reconcile.swift` / `History+Search.swift` lowers one
file's line count but leaves one 900-line object, the same state surface, and the
same singleton dependencies. It fails the deletion test and is rejected as the
final shape. A temporary extension move is allowed only when immediately
consumed by a real type extraction in the same milestone; it is not a deliverable.

### B. Five-to-seven-type big bang

Extracting list state, projection, search, mutations, legacy, and UI adapters in
one change makes Swift Observation, SwiftData identity, async search generation,
and UI effects fail together. It is unreviewable without local Xcode and violates
the compile-boundary rule. Rejected.

### C. Stable facade plus deep modules — selected

Keep the external `History` interface stable and replace one responsibility at
a time behind it. Delete dead behavior first. Each new module owns meaningful
state and behavior behind a small interface and has an immediate test consumer.

## 3. Final module shape

```text
Views / Intents / AppState / tests
                 │
                 ▼
        @Observable History facade
          │       │        │
          │       │        └── HistoryMutations
          │       │              persistence + clipboard + effects
          │       └────────── HistorySearchSession
          │                      query + generation + actor + corpus/apply
          └────────────────── HistoryStoreProjector
                                 load + consume + reconcile + decorator reuse
                    │
                    ▼
             HistoryListState
                 all + items + ordering/index invariants

History modules ──emit──▶ HistoryUIEffect values
AppState ──configures/consumes effect sink──▶ Popup / NavigationManager

HistoryStoreProjector / HistoryMutations ──▶ HistoryPersistence seam
SwiftDataHistoryPersistence ──▶ ModelContext
```

### 3.1 `History`

`History` remains the application-facing facade so no view/intent migration is
required. It composes the modules, exposes the existing `items`, `all`,
`searchQuery`, `lastPersistError`, pinned/unpinned accessors, and command methods,
and owns only Defaults wiring plus cross-module orchestration that cannot belong
to a narrower module. A forwarding facade is intentional; its interface is the
stable application seam, while implementations and dependencies move behind it.

### 3.2 `HistoryListState`

One `@MainActor @Observable final` module owns `items` and the unobserved complete
`all` collection. It exposes named mutations rather than arbitrary array edits:
replace, insert in sorted position, remove stored identities, and publish a
visible projection. The facade retains compatibility setters only for existing
tests during migration; production modules use the named interface.

The first extraction includes an Observation-framework test proving that reads
through `History.items` are invalidated when nested list state changes. If that
test cannot be made reliable, `items` stays stored on the facade and B2 uses a
non-observable list module; the design must not guess about SwiftUI propagation.

### 3.3 `HistoryStoreProjector`

This module owns the main-side SwiftData projection algorithm:

- complete load and limit enforcement;
- `.added` / `.merged` incremental application;
- trimmed persistent-ID removal;
- full reconcile fallback and decorator reuse/cleanup;
- store-to-list ordering through `Sorter`.

Its interface is `load`, `consume`, and `reconcile`; callers do not learn fetch
descriptors, `model(for:)`, binary insertion, or reuse rules. It receives
`HistoryPersistence`, list state, search session, decorator factory, and effect
sink. The persistence seam gains only operations the projector immediately uses.

### 3.4 `HistorySearchSession`

This module owns the query stream, debounce consumer, `SearchActor`, generation,
in-flight task, corpus updates, matching, and match-to-decorator resolution. Its
interface is query update, invalidate, wait, refresh, and corpus mutation. The
legacy synchronous `Search` engine is removed under C3 while this module lands;
an empty query publishes the complete list directly.

The module maintains a `[UUID: HistoryItemDecorator]` lookup with the list/corpus
so apply is O(matches), closing DS-012. Corpus mutation and generation ordering
are characterized before extraction, including the accepted one-event lag rule.

### 3.5 `HistoryMutations`

This module owns clear, clear-all, delete, pin, select, cleanup, shortcut refresh,
and synchronization events sent back to the ingest actor. It depends on list
state, persistence, search session, clipboard operations, pin/sort helpers, and
the value-effect sink. It does not know `AppState` or create global dependencies.

### 3.6 UI effect inversion

`HistoryUIEffect` is a closed value enum for the effects currently expressed by
direct `AppState.shared` calls: popup close/resize, selection, highlight-first,
and scroll target. `AppState` configures a sink during composition and applies
the values to its owned popup/navigator. Tests install a recording sink. This is
real inversion: the production sink captures its owning `AppState`; no adapter
method reaches back through `AppState.shared`.

## 4. Execution order

The numeric roadmap labels describe outcomes, not a safe dependency order. The
safe implementation sequence is:

1. **B3** — add test-only live-path seeding and migrate non-legacy behavior tests.
   Dedup/trim assertions already covered by actor tests are removed from the
   legacy suite; sessionLog-only behavior is documented as production-dead.
2. **B4** — delete legacy add/sessionLog/adapter code and its false comments.
3. **B5** — introduce and prove one list/order mutation chokepoint before moving
   the search machinery.
4. **B2a** — invert UI effects, eliminating `History → AppState.shared`.
5. **B2b** — extract list state with observation proof.
6. **B2c** — extract search session and close C3/DS-010/012/029 where evidence
   supports it.
7. **B2d** — extract store projector and complete DS-022 through a now-real seam.
8. **B2e** — extract mutations and reduce the facade to composition/orchestration.

Each item is split further into red test, minimal implementation, and docs
commits. Only code/test heads trigger CI; documentation-only commits do not.

## 5. Invariants and error handling

- `@Model` values never cross actor boundaries; only existing Sendable DTOs and
  persistent identifiers do.
- Ingest remains one background transaction.
- Complete retained history remains in memory; no windowing or memory-motivated
  startup regression.
- Search invalidation precedes a destructive list/order mutation; stale apply
  remains guarded by generation and query equality.
- `.merged` removes the actor-reported duplicate persistent ID.
- Load/reconcile errors record `lastPersistError` and leave the previous list
  intact; no empty-on-failure behavior returns.
- Extracted modules stay `@MainActor`; no `@unchecked Sendable` or
  `nonisolated(unsafe)` is introduced.
- Default SwiftLint behavior is followed where practical. No length threshold is
  raised and no new lint disable is added to permit a large module.

## 6. Verification

Every behavior/refactor follows red-green-refactor on GitHub Actions because no
local Apple toolchain exists. One workflow at a time. A real failure cancels the
remaining matrix immediately; known runner-contention flakes are recorded and
not rerun. Each code milestone requires generated-project zero drift, strict
SwiftLint, unit, both UI shards, and performance shards unless the only failure
is a previously classified unrelated contention flake.

Final structural audit must show:

- zero live `history.add` / `MainActorIngestorAdapter` / `sessionLog` references;
- zero `AppState.shared` and direct `Storage.shared.context` references in the
  facade and extracted History modules;
- `History.swift` is a small facade rather than a redistributed god object;
- no extracted module recreates the facade's full interface;
- B2–B5 and affected DS findings are updated in the master roadmap and verdict
  matrix with commit/run evidence.
