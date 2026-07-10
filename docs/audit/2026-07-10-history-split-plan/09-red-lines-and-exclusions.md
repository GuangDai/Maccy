# 09 — Red Lines, Exclusions, and Open Forks

**Normative** for work described in this suite · Complements master roadmap §7

---

## 1. Red lines (do not)

### Architecture / product correctness

1. Do **not** weaken post-hash `==` / `dataLikelyEqual` contracts.  
2. Do **not** casually edit C++ UTF-8 validation.  
3. Do **not** split the ingest **single transaction**.  
4. Do **not** drop search generation / title-equality guards.  
5. Do **not** use `mainContext.reset()` as a memory “fix.”  
6. Do **not** change user-visible behavior unless the step requires it and tests lock it.

### Process / PR shape

7. Do **not** mix **structure + behavior** in one PR.  
8. Do **not** move directories + change dedup + change load in one PR.  
9. Do **not** reword logs solely to dodge CI self-scan (allowlist fault-injection logs).  
10. Do **not** push without CI as truth (no local Xcode).

### Hollow / over-design (this suite)

11. Do **not** reintroduce **UIEffectPort** (or any port whose only impl calls `AppState.shared`).  
12. Do **not** ship **standalone DS-022** port routing (`05`).  
13. Do **not** do **lint-only** `extension History` multi-file splits (`02`, `03`).  
14. Do **not** build a generic **EventBus**, search index without measurement, **repository pyramid**, or **full DDD package tree** in one migration.  
15. Do **not** extract `@Observable` state (`items`, `searchQuery`) into child types as the first split move.  
16. Do **not** split the **Search** cluster first when a file split is forced (`07`).  
17. Do **not** claim D4 as a perf win without **S1 measurement** (`06`).  
18. Do **not** “fix” SwiftLint debt by raising thresholds further above 1000.

---

## 2. Explicit exclusions from this suite’s near-term scope

| Item | Why excluded now |
|------|------------------|
| Full 5–7 type History decomposition | End-state shape only; no consumer for most types |
| AppState inversion | Needs event/projection design; B1 proved wrong first step |
| B3/B4 test migration | High effort; only forced by gate or dual-path bug hunt |
| D5 actor trim O(n) | Separate Wave D item; pair later |
| C2 SignatureIndex delete sync | Domain track; small hooks OK but not “History split” |
| C3 single MatchEngine | After D4 preferred; own milestone |
| E4 paste-stack delete | Product decision; recommended but not frozen here |
| C6 ItemID UUID column | Low; defer |
| Stock SwiftLint restore to 350 type_body | Repo-wide blast radius |

---

## 3. Open forks (need human call)

| ID | Question | Blocks | Recommendation in this suite |
|----|----------|--------|------------------------------|
| **D0** | Wire / delete / test-only `VisibleWindowLoader` + fix `newBackgroundContext` docs? | D1, and S2b cascade | Decide when measurement no-gos D4 or when memory track prioritizes D1 |
| **E4** | Delete multi-select/paste-stack subtree? | Cleanup size | Delete if not a staged feature |
| **Lint** | Soft band vs named disables vs leave 1000/1000? | Process only | Option A/B in `02`; not blocking D4 |
| **D3** | Ingest coalesce mailbox? | Copy storms | Product; independent |
| **C2 style** | noteRemoved vs dirty rebuild vs wait for events? | Index growth | Prefer dirty rebuild; not History split |

**B0 (History split granularity)** — **closed** by this suite: defer; smaller cuts only on gate; no 5–7 first cut.

---

## 4. Supersessions

| Prior text | Superseded by |
|------------|----------------|
| Master roadmap §5 #3 open “5–7 vs smaller first cut” | **B0 closed:** defer split; gate in `07` |
| Master roadmap near-term “D4 or Load ADR” without measure | **Measure-first D4** then cascade (`06`, `08`) |
| Master roadmap B2 “file split soon as structure spine” | **Deferred**; structure not highest leverage post–Wave A for History |
| First synthesis “DS-022 standalone next structure win” | **`05` hollow finding** |
| Grilling note “extensions measured separately for type_body” | **`02` stock excluded_types correction** |
| “AppState ×22” | **×23** (`01`) |

The short decision seed remains valid:

[`../2026-07-10-history-split-grilling/00-decision.md`](../2026-07-10-history-split-grilling/00-decision.md)

This suite is the **expanded authority** (SwiftLint forensics, anatomy, execution board).

---

## 5. Compliance

Writing this document does not change product code. Execution follows `08` under project AGENTS/CI rules.
