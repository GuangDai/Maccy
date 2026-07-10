# 03 — Hollow-Work Test & B1 Lesson

**Baseline:** B1 revert `bfcf671` · grilling decision · this suite’s re-verification · **Normative for all Wave B PRs**

---

## 1. The non-negotiable test

A structural change is **allowed** only if it delivers **at least one** of:

| Code | Concrete value |
|------|----------------|
| **C** | **Correctness** — closes a real defect (behavior or invariant) |
| **P** | **Measured performance** — CI/perf evidence, not narrative |
| **T** | **Test unblocked today** — a test that exists *or is written in the same PR* and could not work without the change |
| **G** | **Hard gate cleared** — a real blocker (e.g. forcing-gate in `07`, D1 windowed path) — not a hypothetical future test |

If the change only:

- relocates a singleton call behind a protocol,  
- moves methods between files without changing dependencies,  
- or “enables” future work without C/P/T/G now,

it is **hollow** (Chinese team shorthand used in-session: 脱裤子放屁 — *all ceremony, no effect*).

---

## 2. B1 post-mortem (UIEffectPort)

| Item | Detail |
|------|--------|
| Intent | DS-007 — break `History` → `AppState.shared` ×23 |
| Shape | Protocol + production adapter |
| Failure mode | Adapter methods each called `AppState.shared` |
| Runtime | Unchanged |
| Testability | Not unblocked for real AppState behavior |
| Outcome | **Reverted**; roadmap demoted B1 (`bfcf671`) |
| Real fix | **Inversion**: History publishes effect intents; UI subscribes and owns AppState |

**Generalization:** `Foo → Port → Adapter → Foo.shared` is not dependency inversion. It is **indirection theater**.

---

## 3. Claim matrix (proposals × hollow test)

| Proposal | C | P | T | G | Hollow? | Notes |
|----------|---|---|---|---|---------|-------|
| Pure `extension History` multi-file split | — | — | — | lint headroom only | **Yes** | Same type; project lint doesn’t force real types |
| B1-style UIEffectPort again | — | — | — | — | **Yes** | Proven |
| Full 5–7 type extract now | — | — | future only | — | **Premature** | Observation cost; red-line DDD tree |
| Standalone DS-022 port route | — | — | redundant / thin | — | **Yes standalone** | See `05` |
| D4 with measurement | — | **P** | regression gate | — | **No** | Primary next |
| D4 without measurement | — | claimed | — | — | **Risky** | May be ceremony if already cheap |
| B5 generation chokepoint | **C** (structural) | — | can lock | — | **No** (small) | After or beside D4; no file split required |
| B3/B4 delete dead `add` | cleanup | — | forces live-path tests | headroom **G** | **No** when gate fires | Prefer before extension split |
| Real `StoreProjector` at D1 | — | memory path | windowed tests | **G** D1 | **No** when D1 | Only justified real type soon |
| Restore stock lint 350 in one PR | — | — | — | — | **Harmful** | Repo-wide red; wrong sequencing |

---

## 4. Corrections to earlier / intermediate claims

### 4.1 “DS-022-close has standalone concrete value”

**Revised (grilling + re-check): no as a standalone PR.**

Why the first synthesis over-weighted it:

- Port *direction* is right (complete the channel eventually).  
- `fetchAll` already exists — load dual-path looks like “easy win.”  
- Intuition: “fake persistence can intercept load.”

Why it fails the hollow test **today** (detail in `05`):

- No new correctness (error paths already record/return).  
- Runtime byte-identical.  
- Load/syncAll failures **already tested** via DEBUG force flags.  
- Shape is B1-like: still ends at `Storage.shared` inside the only adapter.

### 4.2 “file_length forces the split”

**False as architecture mandate.** True only as **CI risk** if someone adds >22 lines without extract/delete. Prefer delete dead code or D4 shrink over multi-file ceremony.

### 4.3 “Extension split clears type_body_length”

**Misleading.** Stock excludes extensions from `type_body_length`. Project thresholds already allow a 958-line class. See `02`.

### 4.4 “AppState sites = 22”

**Correct count at HEAD: 23.**

### 4.5 “Structure before all History-touching D/C work”

**Softened after Wave A.** D4/D6/B5 can land in the monolith safely if PRs stay small and tested. C2/C3 still *prefer* a quieter file, but that is convenience, not a correctness law.

---

## 5. How to apply the test in PR review

Reviewer checklist:

1. What is the **one** C/P/T/G claim?  
2. Is there a **test or measurement** that would fail without this change?  
3. Does any adapter still call `*.shared` for the dependency we claim to break?  
4. Is this PR **only** moving lines / renaming types?  
5. If “enabling,” what **immediate** next PR consumes the enablement within the same milestone?

If (3) is yes and (1) is only “cleaner,” **reject** (B1).

---

## 6. Relationship to master roadmap red lines

Aligned with [`../2026-07-10-master-roadmap.md`](../2026-07-10-master-roadmap.md) §7:

- No EventBus, repository pyramid, full DDD tree, search index without measurement.  
- Structure ≠ behavior same PR.  
- This suite adds: **no B1-shaped ports; no lint-only extension splits; no standalone DS-022.**

---

## 7. One-line rule

**If you can’t name C, P, T, or G in one sentence, don’t merge the structure PR.**
