# 00 — Executive Summary

**Baseline:** HEAD `bfcf671` · `History.swift` = **978** LOC · **Method:** firsthand source + commit forensics + B0 grilling decision + SwiftLint stock-vs-project comparison · **Read-only product code**

---

## 1. One-paragraph judgment

Splitting `History.swift` **now** is the wrong next step. After Wave A, the highest-leverage History-adjacent work is **measured hot-path improvement (D4)**, not enabling structure. The B1 `UIEffectPort` experiment (reverted 2026-07-10, `bfcf671`) proved that **relocating a singleton behind a protocol is not a design win**. The same hollow shape reappears in (a) pure extension file splits for `file_length` headroom under the project’s 1000/1000 length rules, and (b) standalone DS-022 port-routing when failure paths are already tested via DEBUG seams. The project’s own lint change (`a8365fa`, 2026-06-24) is a second, independent problem: it **removed soft length pressure** and **neutered stock `type_body_length` / `function_body_length`**, so CI only screams at a 1000-line **file** cliff — which already forced a non-architectural paste-stack extract when History hit 1060 lines.

---

## 2. Locked decisions (B0)

| # | Decision | Rationale (short) |
|---|----------|-------------------|
| **B0.1** | **Defer** the History split (files and types) | Wall green (978/1000); D4 shrinks hot path; observation cost dominates real types until D1 |
| **B0.2** | **Next = D4**, gated by **measure-first** n=1000 per-copy baseline | Concrete perf claim; if measurement is noise, cascade to D0 not ceremony |
| **B0.3** | **DS-022-close is not a standalone PR** | Hollow-as-B1 under verification (`05`); folds into later B2/D1 only |
| **B0.4** | D4 transport: **widen `onEvent`**, not `StoreEvent` | ~5 prod sites; zero enum/test-construction churn (`06`) |
| **B0.5** | Split **forcing-gate** only: lint cliff **or** D1 **or** B5 restructure | When fired: delete dead `add` (B3/B4) before extension split; never Search-first (`07`) |
| **B0.6** | AppState×23: **inversion later**, never singleton-wrapping port | B1 already falsified the port approach |
| **B0.7** | Lint policy: **optional separate track**; do not “fix lint by splitting History” | Soft bands / named debt — process, not architecture (`02`) |

---

## 3. What “next” means in commits

```text
1. feat(d4): per-copy@n=1000 perf baseline (measure only)
2. interpret CI → either implement D4 (06) or open D0 Load ADR
3. (optional, separate) lint warning-band / named-disable policy
4. only later: B3/B4 delete legacy add → optional History+Reconcile → real StoreProjector with D1
```

Detail: [`08-ordered-execution-plan.md`](08-ordered-execution-plan.md).

---

## 4. Why not “structure spine first” (roadmap tension)

[`../2026-07-10-master-roadmap.md`](../2026-07-10-master-roadmap.md) §2 still labels Wave B structure as “highest leverage.” That was true when the god object **blocked safe correctness fixes**. Wave A **already landed those fixes inside the monolith**. After B1’s hollow failure and the verification’s severity recalibration:

| Claim | After Wave A |
|-------|----------------|
| “Must split before touching History” | **False** — Wave A proved site-local fixes + CI are viable |
| “Structure enables D4” | **False** — D4 is a narrow hot-path change; split first only creates merge conflict risk |
| “DS-022 is the first structural win” | **False as standalone** — see `05` |
| “file_length forces real architecture” | **False** — under project lint, extension-only clears the wall without new types |

**Recalibration:** for History, **concrete value (D4 / D0 / dead-code B3–B4) before enabling structure.** Structure returns when a forcing-gate or D1 needs a real boundary.

---

## 5. The three anti-patterns to refuse

1. **B1-shaped ports** — protocol + adapter that still calls `*.shared` in every method; runtime identical; tests not newly unblocked.  
2. **Lint theater** — move methods into `extension History` / new files solely to stay under 1000 lines without changing dependencies.  
3. **5–7 type big-bang** — full ListState / StoreProjector / SearchSession / Mutations / LegacyWriter / UIEffectPort migration in one wave (red line: DDD package tree; `@Observable` cost).

---

## 6. Open forks this suite does **not** close

| Fork | Owner | When it enters |
|------|-------|----------------|
| **D0** Load ADR (wire / delete / test-only `VisibleWindowLoader`) | Product + memory track | If D4 measurement is negligible (`06` § cascade), or when D1 is scheduled |
| **E4** Delete dead paste-stack (~250 LOC) | Product | Anytime; parallel; reduces dead surface including `History+PasteStack` |
| **C6** ItemID stored UUID | Defer (Low) | Not History-split related |
| **Lint thresholds restore** | Engineering process | Optional; must not big-bang stock 350 type-body without plan |

---

## 7. Success criteria for “we did the History plan”

| Criterion | Met when |
|-----------|----------|
| B0 frozen | This suite + grilling decision agree; no open “should we split now?” thrash |
| D4 either landed or deliberately skipped | Measurement on CI; if skip, D0 decided with reason |
| No hollow PRs | No UIEffectPort-v2, no DS-022-only PR, no extension-only “refactor(history): split for lint” |
| Split only if forced | Gate in `07` documented in the PR that finally splits |

---

**One-line summary:** Defer split; measure then D4; reject hollow ports and lint theater; treat custom SwiftLint 1000/1000 as process debt, not as architecture pressure.
