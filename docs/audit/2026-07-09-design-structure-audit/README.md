# 2026-07-09 Design Structure Audit (English, rewritten)

| Field | Value |
|-------|--------|
| **Role** | Authoritative **design / structure / domain / pipeline / cohesion-coupling** audit for HEAD analysis |
| **Baseline HEAD** | `6cd37c8` (`6cd37c88be63d29300ebf624eb9c211d1a1ed5c9`) |
| **Language** | English only |
| **Method** | Full-file reads, symbol-level call graphs, step-by-step data-flow traces, production vs test path cross-checks |
| **Constraint** | Read-only analysis of product code. Docs only. Conclusions are recommendations / risks / verification items — not “fixed”. |
| **Does not replace** | `architecture-and-root-causes.md` (architecture roots), `2026-06-27-memory-floor-and-retention/` (memory measurements), `2026-06-28-roadmap-bs5-bs8-gap-audit/` (roadmap completion %). This suite **deepens design structure** and **re-verifies findings against HEAD**. |

## How to read

| Goal | Start here |
|------|------------|
| Executive judgment | [`00-executive-summary.md`](00-executive-summary.md) |
| **Step-by-step data flows (primary evidence)** | [`02-end-to-end-data-flows.md`](02-end-to-end-data-flows.md) |
| **Every finding with file:line evidence** | [`17-findings-catalog.md`](17-findings-catalog.md) |
| **What to do next (ordered playbook)** | [`19-master-playbook.md`](19-master-playbook.md) |
| Terms / ID systems | [`glossary.md`](glossary.md) |
| Per-module deep dives | `03`–`15` |
| Cohesion / coupling matrix | [`16-cohesion-coupling-matrix.md`](16-cohesion-coupling-matrix.md) |
| Target shape (principles) | [`18-target-architecture.md`](18-target-architecture.md) |

## Document index

| File | Contents |
|------|----------|
| `00-executive-summary.md` | System judgment, severity model, top issues, what not to touch |
| `01-project-structure.md` | Repo layout, directory roles, logical layers vs physical layout |
| `02-end-to-end-data-flows.md` | **Traced pipelines**: ingest, load, search, select-out, delete, legacy add, images |
| `03-module-composition-root.md` | `AppDelegate`, `AppState`, wiring, singletons |
| `04-module-history.md` | `History` god-object (989 LOC) |
| `05-module-history-item-decorator.md` | Row VM, images, observation sync |
| `06-module-models.md` | `HistoryItem`, `HistoryItemContent` |
| `07-module-clipboard.md` | Poll, snapshot, write-back, paste |
| `08-module-ingest.md` | Actor, filter, SignatureIndex, DTOs |
| `09-module-search.md` | `Search` vs `SearchActor`, corpus |
| `10-module-image-processing.md` | ImageIO pipeline, caches |
| `11-module-storage.md` | SwiftData container, loader, persistence dual paths |
| `12-module-engine-core-processor.md` | Engine, fingerprints, C++ |
| `13-module-ui-state.md` | Popup, navigation, slideout, memory governor |
| `14-module-views.md` | SwiftUI surface |
| `15-module-settings-intents-extensions.md` | Settings, Intents, Extensions |
| `16-cohesion-coupling-matrix.md` | Cohesion scores, coupling types |
| `17-findings-catalog.md` | **DS-xxx findings** with evidence |
| `18-target-architecture.md` | Keep / split / merge / remove |
| `19-master-playbook.md` | Ordered remediation steps |
| `glossary.md` | Domain terms, three IDs, two signatures |

## Evidence conventions

- Paths relative to repo root unless absolute.
- Line numbers are for baseline HEAD `6cd37c8`; if the tree moves, **trust symbol names** and re-grep.
- Severity: **Critical** (correctness / data loss risk), **High** (major design debt blocking safe change), **Medium**, **Low**.
- Confidence: **High** (closed path in source), **Medium** (needs runtime / fault injection), **Low** (inference).

## Related authorities

| Doc | Use for |
|-----|---------|
| [`../2026-07-09-design-audit-verification/`](../2026-07-09-design-audit-verification/) | **Verification + recalibration of THIS audit** (13-agent verify+refute). Mechanisms here all confirmed; **severity recalibrated** (6 overstated) and **19 new issues** added. Priority/severity → trust the verification; design mechanisms → trust this audit. |
| [`../architecture-and-root-causes.md`](../architecture-and-root-causes.md) | Historical architecture narrative |
| [`../2026-06-27-memory-floor-and-retention/`](../2026-06-27-memory-floor-and-retention/) | Memory floor ~62 MB, retention |
| [`../2026-06-28-roadmap-bs5-bs8-gap-audit/`](../2026-06-28-roadmap-bs5-bs8-gap-audit/) | BS completion % |
| [`../2026-07-04-bs5-search-redesign/`](../2026-07-04-bs5-search-redesign/) | Search redesign ADRs |

**HEAD re-checks that supersede older gap text when they conflict:**

1. Candidate-path fingerprint backfill exists (`BackgroundClipboardIngestor.backfillMissingFingerprints`).
2. `HistoryItem.dataFromFileIfAllowed` returns `nil` on size-read failure (no longer `(fileSize ?? 0)` always-true).
3. Shared `DecodedImageCache` type is gone; `MemoryGovernance` documents intentional removal.
4. `Collection.item(before:)` guards `currentIndex > startIndex` (prior trap finding outdated for HEAD).
