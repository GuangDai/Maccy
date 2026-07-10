# 08 — Ordered Execution Plan (commits / PRs)

**How to use:** one primary goal per PR; TDD for behavior; CI green via `macOS 26 ARM CI`; no local Xcode.  
**Authority:** this suite + master roadmap for non-History items.

---

## 0. Status board

| Step | Name | Status | Depends on |
|------|------|--------|------------|
| S0 | Freeze B0 (this suite) | ✅ docs | Wave A done |
| S1 | D4 measure-first baseline | ⬜ | S0 |
| S2a | D4 implement | ⬜ | S1 go |
| S2b | Cascade D0 if S1 no-go | ⬜ | S1 no-go |
| S3 | Optional lint policy | ⬜ | none (parallel) |
| S4 | Optional D6 defaults→reconcile | ⬜ | none (after or with S2a carefully) |
| S5 | Optional B5 generation chokepoint | ⬜ | Wave A (done) |
| S6 | B3/B4 only if gate/headroom | ⬜ | G-lint or cleanup drive |
| S7 | Extension / StoreProjector | ⬜ | `07` gate |

---

## 1. Near-term path (default)

### S1 — Measure (no behavior)

| | |
|--|--|
| **Commit** | `feat(d4): add per-copy@n=1000 perf baseline` |
| **Code** | Perf test in existing harness; n=1000 prefilled history; measure `consume(.added)` path (and document what is included) |
| **CI** | Read perf shard; paste numbers into PR description |
| **Done when** | Baseline recorded; test stays as regression gate |
| **Forbidden** | Changing `syncAllToStore` in this commit |

### S2a — D4 implement (if measurement justifies)

| | |
|--|--|
| **Commits** | (1) failing tests for trimmed-id apply + dup orphan; (2) `perf(d4): apply ingest trimmed persistent IDs on consume` |
| **Design** | Full detail in [`06-d4-design.md`](06-d4-design.md) |
| **Touch** | Ingestor `onEvent`, `commit` id capture, AppDelegate, `History.consume` / `insertIncrementally` |
| **Done when** | Happy path O(deleted); fallback safe; `NEW-history-spine-2` closed in notes |
| **Forbidden** | File split; DS-022 port expansion; D5 in same PR |

### S2b — Cascade (if measurement says D4 is not a perf win)

| | |
|--|--|
| **Action** | Open / decide **D0 Load ADR** (wire / delete / test-only `VisibleWindowLoader` + fix false “production calls this” docs on `newBackgroundContext`) |
| **Doc** | Short ADR under `docs/audit/` or appendix to master roadmap |
| **D4** | Skip or park as pure D1 prep only if D1 is scheduled immediately |

---

## 2. Parallel optional steps (do not block S1)

### S3 — Lint policy (process)

| | |
|--|--|
| **Commit** | `chore(lint): restore length warning band` **or** `chore(lint): re-label known god-file debt` |
| **Spec** | [`02-swiftlint-policy-audit.md`](02-swiftlint-policy-audit.md) §7 |
| **Done when** | Policy chosen; no surprise mass fail without listed allowouts |
| **Forbidden** | “Fixed” by History extension-only moves |

### S4 — D6 defaults reload

| | |
|--|--|
| **Commit** | `perf(d6): loadAfterDefaultsChange uses reconcileWithStore` |
| **Test** | Decorators reused (ids stable) / no full image storm on sort toggle (as practical) |
| **Forbidden** | Same PR as D4 if conflict risk high — prefer sequential |

### S5 — B5 generation chokepoint

| | |
|--|--|
| **Commit** | `refactor(b5): centralize list-mutation search invalidation` |
| **Shape** | Private entry used by load/pin/delete/clear/select/search kickoff |
| **Test** | Existing generation tests stay green; optional single oracle test |
| **Forbidden** | New files unless G-B5 forces |

### E4 / C1 (repo hygiene)

Unchanged from master roadmap — parallel, different files where possible.

---

## 3. Deferred path (only if `07` gate fires)

```text
S6  B3 → B4  (delete legacy add)
S7a History+Reconcile.swift  (post-D4, no behavior)
S7b History+Mutations.swift / +SearchSession.swift as needed
S7c StoreProjector type with D1
```

Commit message pattern:

```text
refactor(history): split Reconcile into History+Reconcile (no behavior change)
```

---

## 4. Explicitly cancelled / forbidden near-term PRs

| PR idea | Why forbidden now |
|---------|-------------------|
| `feat(b1): UIEffectPort` | Reverted; hollow |
| `refactor(history): route all Storage via HistoryPersistence` | Hollow standalone (`05`) |
| `refactor(history): extract ListState/SearchSession/...` (big-bang) | Premature; observation cost |
| `refactor(history): extension split for file_length` without gate | Lint theater (`02`, `03`) |
| D4 + file split same PR | structure ≠ behavior |
| D4 + D5 + D0 same PR | un-bisectable |

---

## 5. PR template (History-touching)

```markdown
## Claim (pick one)
- [ ] C correctness: …
- [ ] P performance: … (link CI numbers)
- [ ] T test unblocked: …
- [ ] G hard gate: …

## Hollow check
- [ ] No adapter that only forwards to *.shared for the broken dependency
- [ ] Not line-move only
- [ ] Structure ≠ behavior mixed? if yes, split PR

## CI
- [ ] macOS 26 ARM CI green
- [ ] perf numbers if P
```

---

## 6. Tracking updates after each step

Update in the same docs PR or follow-up:

- This file’s status board (§0)  
- Master roadmap status lines if a Wave D/B item closes  
- Finding ids (`NEW-history-spine-2`, etc.)

---

## 7. Suggested calendar (not binding)

| Session | Work |
|---------|------|
| 1 | S1 baseline + CI numbers |
| 2 | S2a tests red → green **or** S2b D0 write-up |
| 3 | Optional S5 or S4 or S3 |
| later | Gate-driven S6/S7 only |

---

## 8. One-line execution summary

**Docs frozen → measure D4 → implement or cascade to D0 → optional B5/D6/lint → split only on gate after deleting dead legacy weight.**
