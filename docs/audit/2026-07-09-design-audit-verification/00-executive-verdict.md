# 00 — Executive Verdict

**Baseline:** HEAD `6cd37c8` (confirmed) · **Method:** 13-agent verify+refute workflow + firsthand grep · **Read-only**

---

## 1. One-paragraph judgment

The design audit is **right about what the code does** and **wrong, systematically, about how bad it is**. Mechanism accuracy is excellent (27/34 confirmed verbatim; measurements land exactly — 989 LOC, 23 sites, 171/26, 217 LOC). But the audit scores *mechanism presence*, not *realized impact*, so it overstates severity wherever a defect **self-heals** (DS-002: next popup reloads the intact store), has a **dormant trigger** (DS-025: no prod path leaves a pending insert), or is **latent-only** (DS-019: ItemID is never persisted, so a description-format change is absorbed on relaunch). The grilling's most valuable output is not these downgrades — it is the **20 issues the audit never raised**, one of which (silent session-wide dedup disable, `NEW-dedup-ids-1`) is more dangerous than most "High" findings, and the exposure of a **whole bug class** (search-generation discipline) the audit sampled only once (DS-013).

---

## 2. The three findings that change the roadmap

These three are the verification's load-bearing contributions. Each re-shapes the playbook.

### 2.1 `NEW-dedup-ids-1` — silent session-wide dedup disable (the most serious missed defect)

`ensureDedupIndexInitialized` (`ClipboardIngestor.swift:346-353`) does `(try? modelContext.fetch(...)) ?? []`. A **single transient fetch failure on the first ingest after launch** yields `items = []`, registers nothing, and sets `dedupIndexInitialized = true` **for the whole process**. Every subsequent copy then queries an **empty candidate set** → no duplicate is ever found → **every copy, including a byte-identical re-copy, creates a brand-new `HistoryItem`**. Unlike `commit()` (which logs on failure at `:200`), this swallow emits **no log**. The user sees a silently-growing history with no dedup and no signal.

**Why this outranks the audit's "Critical" DS-002:** DS-002 is a transient empty panel that recovers on the next open and never deletes data. This defect **silently corrupts the user's history shape** (duplicate rows accumulate) for the entire session, with zero diagnostic. Trigger likelihood is comparable (both hinge on a SwiftData fetch throwing). **Promote to top-of-Wave-A.**

### 2.2 The `searchGeneration` discipline is a bug *class*, not DS-013 alone

The audit found DS-013: `togglePin` doesn't invalidate in-flight search. The grilling found that `invalidateInFlightSearch()` is called by `clear`/`clearAll`/`delete` but **uniquely omitted** by three more order/list-mutating operations:

| Op | Omits invalidation? | Symptom | New ID |
|----|---------------------|---------|--------|
| `togglePin` (702) | yes | stale matches applied post-pin (the audit's DS-013) | — |
| `load()` (269) | yes | **empty result list** on a sort/pin Defaults-change during search (fresh decorator UUIDs defeat the apply filter) | `NEW-history-spine-3` |
| `select()` (665) | yes (clears query in a deferred `Task`, never invalidates) | stale apply post-select (masked because popup closes) | `NEW-history-spine-4` |

The common fix is one line per site (`invalidateInFlightSearch()`) — but the real lesson is that **generation discipline is not centralized**; it relies on each mutation remembering to call it. This argues for a single "any list mutation bumps generation / cancels in-flight" chokepoint (relevant to the History split, Wave B).

### 2.3 "Incremental per-copy reconcile" is O(n) in two places — the marketing is ahead of the code

The roadmap/memory frame the live ingest path as incremental. The grilling measured it: the per-copy path is **O(rows) on the main actor** (`syncAllToStore` fetches *all* identifiers + linear-scans `all` on every copy — `NEW-history-spine-2`, self-acknowledged in the comment at `:418`) **and O(n) on the ingest actor** (`commit` fetches + sorts the *entire unpinned table* every copy to find the eviction tail — `NEW-ingest-dualpath-1`). At n=1000 that is ~1000 identifiers fetched + 1000 decorators scanned on main, plus a 1000-row fetch+sort on the actor, **per copy**. This is the real connection to the BS-4/6 read-path/memory work, and it is invisible in the audit's "incremental" framing.

---

## 3. Severity recalibration (summary — full rationale in `03`)

| ID | Audit | Verified | Why |
|----|-------|----------|-----|
| DS-002 | Critical | **High** | Mechanism real & silent, but **no row deletion** and it **self-heals** on next popup — *unless the store is genuinely broken*, in which case `prewarm`'s `load()` also throws and is swallowed, masking the root cause. Silent defect, not data destruction → High. |
| DS-006 | High | **Medium** | Structural/testability only; no runtime or correctness impact. |
| DS-016 | Medium | **Low** | `MainActorIngestorAdapter` is **fully dead** (0 instantiation sites), not merely "residual". |
| DS-017 | Medium | **Low** | `IngestPlan` is nominal — definition + one Sendable test only. |
| DS-019 | Medium (implied) | **Low (refuted as cross-relaunch risk)** | `ItemID` is **not persisted**; the index is rebuilt from the store on first ingest every process. A description-format change is absorbed; only a latent reliance on an undocumented format remains. |
| DS-025 | Medium | **Low** | No-save-before-predicate structure is real, but **no production path leaves a pending insert on the main context**; trigger dormant. (Also: the audit's file path is wrong — see `03`.) |
| DS-029 | Medium | **Low** | Fire-and-forget corpus tasks can lag one item; documented, self-correcting, narrow. |
| DS-008 | Low/Med | **Low but larger** | Dead surface is bigger than enumerated (`filteredTypes`, `supportedTypes`/`disabledTypes` cascade, `ignoredRegexps` NSCache all dead too). |
| DS-028 | Low/Med | **High (cleanup value)** | Gates a **~250 LOC unreachable paste-stack/multi-select subtree** (`PasteStack.swift`, `History+PasteStack.swift`, 3 views, KeyChord/KeyHandling branches). |

The adversarial "refute" pass re-tried the six correctness-critical findings (DS-002, 003, 009, 013, 019, 025). **All six `agrees=true`** — the skeptics confirmed the downgrades after genuinely trying to refute them. The single sharpest adversarial insight: for DS-002, the self-heal argument is *almost* right but **fails exactly when it matters** (the broken-store case), which is what rescues it from Medium up to High rather than down.

---

## 4. Recalibrated priority order (re-weights the playbook's Wave A)

The design audit's Wave A = {DS-002, DS-013, hygiene}. After verification, the correctness-first order is:

| Rank | Item | Why this order | Source |
|------|------|----------------|--------|
| 1 | **`NEW-dedup-ids-1`** silent session dedup disable | Silent correctness regression, no log, whole-session | new |
| 2 | **DS-002** syncAll wipe + DS-023/`NEW-ingest-dualpath-4` error swallowing | Silent empty UI / lost copies; fix pattern already exists in sibling `reconcileWithStore` | audit + new |
| 3 | **Generation-discipline bug class**: DS-013 + `NEW-history-spine-3` (load) + `-4` (select) | One-line-per-site fix; centralize during Wave B | audit + new |
| 4 | **`NEW-history-spine-2` + `NEW-ingest-dualpath-1`** per-copy O(n) × 2 | The real hot-path cost behind the "incremental" label | new |
| 5 | **`NEW-storage-load-models-1`** dead `newBackgroundContext` + false docstring + **DS-004** Load ADR | Decide wire-vs-delete; kill the false "production calls this" claim | new + audit |
| 6 | **DS-001/003/007** History split + dual-path + AppState coupling | The structure spine (unchanged from audit) | audit |
| 7 | **`NEW-singletons-intents-misc-1`** ~250 LOC dead paste-stack subtree (with DS-028) | High-value cleanup, low risk | new + audit |
| 8 | **DS-005/008/009/010/015/019/030** domain consistency | Mostly Low after recalibration; batchable | audit (re-weighted) |

**What this changes vs the audit's playbook:** Wave A gains `NEW-dedup-ids-1` (now #1) and the generation bug-class (#3); the "incremental" perf items (#4) move up because they're concrete and measured; DS-019 drops out of the structural-risk tier (refuted); the Load ADR (#5) must now also decide the fate of the falsely-documented `newBackgroundContext`.

---

## 5. What the audit got right (do not re-litigate)

- **Mechanism accuracy is high.** Where the audit says code does X, the code does X. Trust the `02` flow traces.
- **Measurement precision is exceptional.** Every LOC/count the author checked landed exactly (989, 23, 171/26, 217, 29 root files, 8+3 UTI strings, 6 `fetchWindow` call sites).
- **The structural thesis holds.** History is a god object; dual write paths exist; the multi-projection consistency is best-effort; `@Model` never crosses actors. The target architecture (`18`) and the split axes (`16` §5) are sound.
- **The red lines (`19` §6) are correct.** Do not weaken post-hash `==`, do not split the ingest transaction, do not `mainContext.reset()` for memory.

---

## 6. Decisions the grilling must resolve (input to roadmap planning)

These are the forks that depend on product/architecture judgment, not code facts — they go to the user one at a time:

1. **DS-002 fix shape:** mirror `reconcileWithStore`'s `catch { recordPersistenceError; return }`, or also surface a user-visible error state?
2. **`NEW-dedup-ids-1` fix shape:** retry the init fetch, or fail-loud (log + keep dedup off) so it's diagnosable? (Current behavior is fail-silent.)
3. **Load ADR (D0):** wire `VisibleWindowLoader`, delete it, or keep as test-only with corrected docs — and kill `newBackgroundContext`'s false "production" docstring either way?
4. **Generation discipline:** patch the three sites now (one-line each), or wait and centralize during the History split (Wave B)?
5. **Dead paste-stack subtree (`NEW-singletons-intents-misc-1` / DS-028):** delete the ~250 LOC, or is multi-select/paste-stack a planned feature being staged?
6. **History split granularity:** the audit's 5–7 types (ListState/StoreProjector/SearchSession/Mutations/LegacyWriter + UIEffectPort), or a smaller first cut?

These are taken up in the grilling phase.
