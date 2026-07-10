# 07 — Split Forcing-Gate & Order (when deferred work fires)

**Status:** Split **deferred** until a gate in §1 fires · **Baseline:** HEAD 978 LOC

---

## 1. Forcing-gate (any one)

The History **file/type split** is allowed to start only when **at least one** of:

| Gate | Trigger | Why it’s real |
|------|---------|----------------|
| **G-lint** | A **necessary** change cannot land without exceeding `file_length` 1000 **after** trying delete/shrink first | Hard CI; not optional aesthetics |
| **G-D1** | Load ADR chooses windowed load and implementation starts | `StoreProjector` needs a real second job (window + `all` + IO) |
| **G-B5** | Generation chokepoint work restructures search/mutation entrypoints enough that locality demands a file | Rare; B5 can usually stay in-file |

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

### Phase 1 — Extension split (no new types)

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

### Phase 2 — Real type extraction (sparse)

| Type | When | Notes |
|------|------|-------|
| **StoreProjector** | G-D1 | Owns `all` (`@ObservationIgnored`), IO, window; first justified real type |
| SearchSession type | C3 needs isolated tests | Don’t extract for aesthetics |
| Mutations / CommandService | Intent port (E1) wants narrow API | |
| LegacyWriter | Only if Phase 0 not done and tests still need it | |
| UI effect inversion | With multi-projection events | **Never** B1 port |

**Red line:** no 5–7 type migration in one PR / one week.

---

## 4. What about UIEffectPort?

| Approach | Status |
|----------|--------|
| Protocol + AppState adapter | **Forbidden** (B1) |
| History publishes `HistoryUIEffect` values; AppState/Popup subscribes | **Allowed** later with projector/event model |
| Leave ×23 calls until then | **Accepted** interim cost |

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

**Don’t split until lint/D1/B5 forces it; when forced, delete dead `add` first, then Reconcile extension post-D4, then real StoreProjector only with D1 — never Search-first, never B1 ports.**
