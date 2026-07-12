# 07 — Split Forcing-Gate & Order (when deferred work fires)

**Status:** Gate **fired and split completed 2026-07-13** · **Historical baseline:** HEAD 978 LOC · **Current facade:** 341 LOC

> Completion note: G-B5 fired after B3/B4 deleted the legacy writer and
> `HistoryListState` established the structural mutation chokepoint. C3 then
> supplied the independently tested search-session forcing case; D4 had already
> stabilized incremental projection. The implementation used real cohesive
> types (`HistoryListState`, `HistorySearchSession`, `HistoryStoreProjector`,
> `HistoryMutations`) and value UI-effect inversion. The historical decision
> tree below remains useful as the explanation for why the earlier hollow split
> was deferred.

---

## 1. Forcing-gate (any one)

The History **file/type split** is allowed to start only when **at least one** of:

| Gate | Trigger | Why it’s real |
|------|---------|----------------|
| **G-lint** | A **necessary** change cannot land without exceeding `file_length` 1000 **after** trying delete/shrink first | Hard CI; not optional aesthetics |
| **G-D1** | Load ADR chooses windowed load and implementation starts | `StoreProjector` needs a real second job (window + `all` + IO) |
| **G-B5** | Generation chokepoint work restructures search/mutation entrypoints enough that locality demands a file | **Fired:** list-state ownership plus C3's fake-backed search boundary justified real modules |

**Non-gates (do not split just because):**

- “22 lines of headroom feels scary”  
- “Wave B says so”  
- “DS-001 is still open”  
- “We want cleaner folders”  
- Soft desire to parallelize C3  

---

## 2. Pre-split checklist (always)

Before creating `History+*.swift` or new types:

1. **Can we delete dead weight instead?**  
   - B3 → B4: migrate tests off `add`, delete legacy write path + dead adapter `ingest` (~80+ LOC).  
   - E4: delete paste-stack subtree if product agrees (~250 LOC repo-wide; includes `History+PasteStack`).  
2. **Is D4 done or explicitly skipped?**  
   - Don’t freeze pre-D4 `syncAllToStore` into a new file then rewrite.  
3. **Is this PR behavior-free?**  
   - Structure-only commit messages: `refactor(history): … no behavior change`.  
4. **Hollow test:** name C/P/T/G (`03`). G-lint only after step 1 failed to free enough lines.

---

## 3. Order when the gate fires

### Phase 0 — Prefer deletion over split

```text
B3  seedViaConsume / store+consume helpers; quarantine sessionLog-only tests
B4  remove production add path + MainActorIngestorAdapter.ingest (verify 0 live refs)
```

If G-lint was the only trigger and Phase 0 frees ≫22 lines → **stop; no split.**

### Phase 1 — Extension split (no new types; skipped at execution)

**Only if still over wall or G-D1 prep needs locality.**

| Priority | File | Contents | Why this order |
|----------|------|----------|----------------|
| **1st** | `History+Reconcile.swift` | `consume`, `insertIncrementally`, `syncAllToStore`, `reconcileWithStore`, related DEBUG force flags | Stable **post-D4**; D1 candidate cluster; hot path isolated |
| **2nd** | `History+Mutations.swift` | delete/clear/pin/select/cleanup | Clear change reason |
| **3rd** | `History+SearchSession.swift` | search methods only | **State stays on `History`** (`searchQuery`, generation fields) |
| **Avoid / last** | `History+LegacyWrite.swift` | add family | Prefer Phase 0 delete instead |
| **Never first** | Search-only extract before Reconcile | — | `invalidateInFlightSearch` / generation bug-class is highest patch traffic; moving Search first maximizes rebase pain |

Rules:

- `extension History` only.  
- One file per commit.  
- No AppState inversion in the same PR.  
- No DS-022 expansion required unless G-D1 in the same milestone (then port completion may ride with projector work — still prefer separate commits).

### Phase 2 — Real type extraction (completed incrementally)

| Type | When | Notes |
|------|------|-------|
| **StoreProjector** | DS-022 + stable post-D4 projection | ✅ `HistoryStoreProjector`; owns injected load/consume/reconcile/limit IO, while `HistoryListState` owns lists |
| SearchSession type | C3 needs isolated tests | ✅ `HistorySearchSession`; actor corpus + generation + O(1) lookup |
| Mutations / CommandService | Intent port (E1) wants narrow API | ✅ `HistoryMutations`; fake-backed commands and value effects |
| LegacyWriter | Only if Phase 0 not done and tests still need it | |
| UI effect inversion | With multi-projection events | **Never** B1 port |

**Red line:** no 5–7 type migration in one PR / one week.

---

## 4. What about UIEffectPort?

| Approach | Status |
|----------|--------|
| Protocol + AppState adapter | **Forbidden** (B1) |
| History publishes `HistoryUIEffect` values; AppState/Popup subscribes | **Completed** (`acd04dc`) |
| Leave ×23 calls until then | Historical interim only; direct edge is gone |

---

## 5. Parallel tracks that must not fight the gate

| Track | Touches History? | Guidance |
|-------|------------------|----------|
| C1 filter cleanup | No | Anytime |
| E4 paste-stack delete | `History+PasteStack` only | Anytime after product yes |
| E1 Intent port | Reads `items`/`all` | Prefer resolve against `all`; don’t wait for full split |
| C2 SignatureIndex delete sync | Mutations + actor | Can land with small `delete` hooks; no full split required |
| C3 MatchEngine | Search cluster | Prefer after D4; file split optional |
| Lint policy (`02`) | `.swiftlint.yml` | Separate PR; never “fixed” by History extensions alone |

---

## 6. Decision tree (ascii)

```text
Need to change History?
  │
  ├─ Is it D4/D6/B5/bugfix?
  │    └─ Yes → do it in monolith (small PR + TDD + CI)
  │
  ├─ Does file_length block the change?
  │    ├─ Try B3/B4 delete / E4 / D4 shrink
  │    └─ Still blocked → Phase 1 Reconcile extension only
  │
  └─ Is D1 starting?
       └─ Phase 2 StoreProjector (+ port completion as needed)
```

---

## 7. One-line gate summary

**The gate fired through B3/B4 deletion + B5/C3 testability after D4; the completed real-type split preserved the anti-hollow rules: no lint-only extensions, no B1 singleton adapter, and no big-bang migration.**
