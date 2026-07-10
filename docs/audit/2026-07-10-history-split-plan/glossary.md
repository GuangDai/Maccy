# Glossary — History Split Plan

Terms used in this suite. Complements design-audit glossary and verification glossary-supplement.

---

## Process / judgment

| Term | Definition |
|------|------------|
| **Hollow work** | Structure change that fails the C/P/T/G test (`03`): relocates coupling, moves lines, or “enables” without immediate correctness, measured perf, unblocked test, or hard gate. |
| **B1 lesson** | UIEffectPort-shaped fixes (protocol + adapter → `*.shared`) are hollow; real decoupling needs inversion or a second real implementation. |
| **C/P/T/G** | Correctness / Performance / Test-unblocked / Gate — minimum concrete-value codes. |
| **Forcing-gate** | Condition under which a deferred History split may start (`07`): G-lint, G-D1, or G-B5. |
| **Lint theater** | File/extension splits done only to satisfy `file_length` without changing dependencies or types’ surfaces. |
| **Measure-first** | Mandatory S1 perf baseline before claiming D4 as a performance win. |
| **Cliff-only lint** | Project config where warning=error=1000 (and soft bands removed) so debt is silent until hard fail. |

---

## Code / architecture

| Term | Definition |
|------|------------|
| **History facade** | Keep type name `History` as the `@MainActor @Observable` API surface for views/intents even if internals extract later. |
| **Store projection / Reconcile cluster** | `consume`, `insertIncrementally`, `syncAllToStore`, `reconcileWithStore` — main-actor mirror of store into `all`/`items`. |
| **Dual IO channel (DS-022)** | Mix of `HistoryPersistence` and direct `Storage.shared.context` use inside History. |
| **Trimmed persistent IDs** | `[PersistentIdentifier]` of models deleted in one ingest (dup + size trim), passed main-side for O(deleted) decorator drop. |
| **onEvent widening** | D4 transport: callback becomes `(StoreEvent, [PersistentIdentifier])` instead of expanding `StoreEvent`. |
| **Legacy add path** | `History.add` + findSimilar/merge/sessionLog — dead in production; test-heavy. |
| **Live ingest path** | `BackgroundClipboardIngestor` → `StoreEvent` → `History.consume`. |
| **Search-generation discipline** | Every list/order mutation must invalidate in-flight search (generation bump); B5 = single chokepoint. |
| **StoreProjector (future)** | Real type owning `all` + IO + windowed load; first justified type extraction at D1. |
| **Effect inversion** | History emits UI effect intents; UI/AppState applies them — opposite of History calling AppState.shared. |

---

## Lint

| Term | Definition |
|------|------------|
| **Stock defaults** | SwiftLint built-in: file 400/1000, type body 250/350 (extensions **excluded**), function body 50/100. |
| **Project thresholds** | `.swiftlint.yml` after `a8365fa`: all three length rules warning=error=1000. |
| **type_body_length excluded_types** | Default `[extension, protocol]` — extensions not counted toward type body length under stock rules. |
| **Headroom** | `file_length` error threshold minus current file LOC (978 → 22 at HEAD). Not an architecture metric. |

---

## Finding / step ids (quick)

| ID | Meaning in this suite |
|----|------------------------|
| **DS-001** | History god object |
| **DS-007** | History→AppState coupling |
| **DS-022** | Dual persistence channel |
| **NEW-history-spine-2** | Per-copy O(n) `syncAllToStore` — **D4** |
| **NEW-ingest-dualpath-1** | Per-copy O(n) actor trim fetch — **D5** (out of near-term) |
| **B0** | History split design decision — **closed: defer** |
| **B1** | UIEffectPort — **reverted / forbidden as port** |
| **B2** | File split — **deferred to gate** |
| **B3/B4** | Migrate off / delete legacy `add` |
| **B5** | Generation invalidation chokepoint |
| **D0/D1** | Load ADR / windowed load |
| **D4** | O(deleted) sync on main |
| **D6** | Defaults reload via reconcile |
| **E4** | Dead paste-stack subtree delete |

---

## Invariants (do not break)

1. `@Model` never crosses actor boundaries — only Sendable DTOs / events.  
2. Ingest write is one transaction.  
3. Search apply is generation-guarded.  
4. `.merged` orphan decorator removal must include **dup** persistent id (D4).  
5. CI is the gate of truth; no local toolchain.
