# 2026-07-10 — History Split Plan (anti-hollow sequencing after Wave A)

| Field | Value |
|-------|-------|
| **Role** | **Authoritative plan for what to do (and not do) about `History.swift`** after Wave A and the B1 revert. Freezes B0 (split design), the hollow-work test, the SwiftLint policy findings, D4 design, and the split forcing-gate. |
| **Baseline HEAD** | `bfcf671` (post-Wave-A; B1 demoted). `History.swift` = **978** LOC. |
| **Inputs** | [`../2026-07-10-master-roadmap.md`](../2026-07-10-master-roadmap.md), [`../2026-07-09-design-audit-verification/`](../2026-07-09-design-audit-verification/), [`../2026-07-09-design-structure-audit/04-module-history.md`](../2026-07-09-design-structure-audit/04-module-history.md) + [`18`](../2026-07-09-design-structure-audit/18-target-architecture.md) + [`19`](../2026-07-09-design-structure-audit/19-master-playbook.md), [`../2026-07-10-history-split-grilling/00-decision.md`](../2026-07-10-history-split-grilling/00-decision.md) (B0 decision seed), firsthand re-read of `History.swift` / `HistoryPersistence.swift` / `.swiftlint.yml` / commit history. |
| **Constraint** | No local toolchain; one small step + TDD + CI; **structure ≠ behavior in the same PR**; no user-visible behavior change unless required; **no surface / ineffective / meaningless work** (B1 lesson). |
| **Does not replace** | Master roadmap (global order), design audit (mechanism map), verification (severity). This suite is the **History-structure + lint-policy specialization** of Wave B/D. |

---

## Headline (one paragraph)

Wave A closed the silent-failure and search-generation defects. **Do not split `History.swift` now.** The next concrete History-touching work is **D4** (`syncAllToStore` O(rows)→O(deleted) per copy), **gated by a measure-first perf baseline** at n=1000. Standalone “close DS-022” (route five `Storage.shared.context` sites through `HistoryPersistence`) is **hollow-as-B1** under verification: no correctness fix, no runtime change, and the failure paths are already tested via DEBUG force-failure seams. Pure extension splits for `file_length` headroom are also hollow under the project’s custom SwiftLint thresholds. Real type extraction is dominated until **D1** (windowed load) or a hard forcing-gate. The custom lint raise of 2026-06-24 (`a8365fa`: length rules → 1000/1000) is **process debt**: it removed soft bands and effectively neutered `type_body_length` / `function_body_length`, rewarding cliff-driven file surgery (e.g. paste-stack extract at 1060 LOC) rather than dependency changes.

---

## How to read

| Goal | Start here |
|------|------------|
| One-page decision + what to do next | [`00-executive-summary.md`](00-executive-summary.md) |
| Measured baseline (LOC, sites, commits, dual IO) | [`01-baseline-inventory.md`](01-baseline-inventory.md) |
| **SwiftLint custom thresholds — what broke** | [`02-swiftlint-policy-audit.md`](02-swiftlint-policy-audit.md) |
| Hollow-work test + B1 post-mortem + claim corrections | [`03-hollow-test-and-b1-lesson.md`](03-hollow-test-and-b1-lesson.md) |
| Responsibility map of `History` (what would split) | [`04-history-anatomy.md`](04-history-anatomy.md) |
| Why DS-022-close is hollow *standalone* | [`05-ds022-hollow-finding.md`](05-ds022-hollow-finding.md) |
| D4 design (widen `onEvent`, not `StoreEvent`) | [`06-d4-design.md`](06-d4-design.md) |
| When the split *does* fire + order | [`07-forcing-gate-and-split-order.md`](07-forcing-gate-and-split-order.md) |
| Numbered execution plan (commits/PRs) | [`08-ordered-execution-plan.md`](08-ordered-execution-plan.md) |
| Red lines, exclusion list, open forks | [`09-red-lines-and-exclusions.md`](09-red-lines-and-exclusions.md) |
| Terms | [`glossary.md`](glossary.md) |

---

## Relationship to sibling docs

| Doc | Relationship |
|-----|----------------|
| [`../2026-07-10-master-roadmap.md`](../2026-07-10-master-roadmap.md) | Global post-Wave-A order. This suite **freezes B0** (roadmap §5 #3) and **recalibrates** “structure spine first” for History: concrete value (D4) before enabling structure. |
| [`../2026-07-10-history-split-grilling/00-decision.md`](../2026-07-10-history-split-grilling/00-decision.md) | Short B0 decision seed from the adversarial panel. **This suite expands it** with SwiftLint forensics, full anatomy, execution steps, and claim corrections (e.g. `type_body_length` default excludes extensions). |
| [`../2026-07-09-design-structure-audit/04-module-history.md`](../2026-07-09-design-structure-audit/04-module-history.md) | Mechanism inventory + target 5–7 types. Still the *shape* authority; this suite is the *sequence* authority. |
| [`../2026-07-09-design-audit-verification/`](../2026-07-09-design-audit-verification/) | Severity + `NEW-history-spine-*` / dual-path issues. D4 closes `NEW-history-spine-2`. |

---

## Status

| Item | Status |
|------|--------|
| Wave A correctness | ✅ done (through `7fb08bd`) |
| B1 UIEffectPort | ❌ tried & reverted; deferred forever as singleton-wrapping port |
| B0 split design | ✅ decided in this suite: **defer split** |
| D4 measure-first baseline | ⬜ open (next) |
| D4 implementation | ⬜ open (after measurement) |
| History file / type split | ⬜ deferred (forcing-gate in `07`) |
| Lint policy restore | ⬜ open optional process track (not History architecture) |

---

**One-line summary:** Defer History split; measure then do D4 via `onEvent` widening; treat standalone DS-022 and lint-only extension splits as hollow; fix lint *policy* separately if desired; real extraction waits for D1 or a hard gate.
