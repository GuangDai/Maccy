# 19 — Master Playbook (Ordered Execution Guide)

**Baseline:** HEAD `6cd37c8`  
**This is the single “what do I do next?” document.**  
**Language:** English · **Product code:** not modified by writing this doc  

Project constraints: no local Xcode; behavior changes via small steps + tests + CI (`macOS 26 ARM CI`). Structure ≠ behavior in the same PR.

---

## 0. How to use this playbook

### 0.1 Modes

| Goal | Action |
|------|--------|
| First global map | Read `00` + `02` Flow A completely while stepping source |
| Pick next coding step | §3 table + §4 for that Step ID |
| Deep-dive one module | §5 checklist + module doc `03`–`15` |
| Find evidence for a finding | `17` then re-grep HEAD |

### 0.2 Hard rules every step

1. One primary DS / Step per PR.  
2. Behavior change requires failing test or reproducible check first (TDD).  
3. No mixed PRs: move files ≠ fix semantics ≠ perf.  
4. Respect red lines (§6).  
5. CI green ≠ design complete — record what was **not** verified.  
6. Dead code: re-`rg` production+tests before delete.  
7. While dual paths exist, tests on `add` ≠ proof for `consume`.  

### 0.3 Step cycle

```text
1 Read this Step + linked docs
2 Locate symbols; sketch 3–10 box data flow
3 Test or reference map first
4 Minimal change
5 Push → CI (poll ≥ 2 min per AGENTS.md)
6 Update progress table §8
7 New issues → §8 backlog; do not expand scope mid-step
```

---

## 1. Global systems view

### 1.1 Truth layers

| Layer | Truth | Code |
|-------|-------|------|
| Disk | SQLite store | Storage container |
| Background write | actor ModelContext txn | BackgroundClipboardIngestor |
| Main entities | mainContext cache | Storage.shared.context |
| UI list | decorators | History.all / items |
| Search | actor corpus | SearchActor |
| Dedup index | actor memory | SignatureIndex (**not** UI-delete-synced) |

### 1.2 Strategy order

```text
Correctness (DS-002…)
  → Single write-path reasoning (map dual paths, then migrate tests)
  → Split History + break AppState reverse calls
  → Domain consistency (rules, index, search engine, IDs)
  → Read path / hot path (load ADR, MainActor hop)
  → Hygiene / long-term gates
```

**Do not start with directory moves or search indexes.**

### 1.3 Parallel tracks (do not fight)

| Track | Content | When |
|-------|---------|------|
| Structure (this playbook) | Dual path, History split, coupling, dead code | Default |
| BS-8 fingerprints | Full backfill metrics, bridge | Parallel with model steps carefully |
| BS-4/6 load/memory | Window loader, blobs | Only after Load ADR (D0) |
| BS-5 cleanup | Single MatchEngine | After B (search clearer) |

---

## 2. Full DS coverage index

| ID | One-liner | Sev | Diff | Wave | Docs | Flow |
|----|-----------|-----|------|------|------|------|
| DS-002 | syncAll fetch fail → wipe UI | Crit | L–M | **A0** | 04,02,17 | E |
| DS-001 | History god object | Crit | H | **B** | 04,16 | * |
| DS-003 | Live vs legacy add | High | M–H | A2→B | 04,02F,08 | F |
| DS-004 | Full load + unwired loader | High | H | **D** | 04,11,02B | B |
| DS-005 | 3 IDs + 2 signatures | High | M | A1→C | glossary,06,08 | * |
| DS-006 | shared bus | High | H | B→E | 03,16 | * |
| DS-007 | History→AppState ×23 | High | M | **B1** | 04,13 | * |
| DS-008 | Dual filter + dead helpers | High | L–M | A1/C1 | 07,08 | A |
| DS-009 | UI delete ↛ SignatureIndex | High | M | **C2** | 08,04 | E/A |
| DS-010 | Dual search engines | Med | M | **C3** | 09,02C | C |
| DS-011 | Ingest MainActor hop | Med | M–H | D2 | 08,02A | A |
| DS-012 | applySearch O(n) id | Med | L | B2/C3 | 09,04 | C |
| DS-013 | pin no search invalidate | Med | L | **A0b** | 09,04 | C |
| DS-014 | limit one-by-one delete | Med | L–M | C4 | 04 | B/E |
| DS-015 | availablePins→Storage | Med | L | C5 | 06 | — |
| DS-016 | MainActorIngestorAdapter | Med | L | B4 | 08 | F |
| DS-017 | IngestPlan unused | Med | L | A1 | 08 | — |
| DS-018 | Intent→AppState | Med | M | E1 | 15,03 | — |
| DS-019 | ItemID String(describing) | Med | M–H | C6 | glossary,08 | A |
| DS-020 | no ingest coalesce — resolved `b754ac6` | Med | M | D3 | 07 | A |
| DS-021 | title gate over-reconcile | Med | M | B/D | 04 | A |
| DS-022 | dual persistence channel | Med | M | B2 | 04,11 | * |
| DS-023 | load/prewarm try? | Med | L | A0/A1 | 03,14 | B |
| DS-024 | Timer tolerance/mode | Low | L | E3 | 07 | A |
| DS-025 | predicate delete pending | Med | M | C | 11,04 | E |
| DS-026 | AppDelegate overload | Low–M | M | E | 03 | — |
| DS-027 | doc drift | Low | L | A1 | 00 | — |
| DS-028 | multiSelectionEnabled false | Low | L | E3 | 13 | — |
| DS-029 | corpus Task races | Med | M | C3 | 09 | C |
| DS-030 | Engine takes @Model content | Med | M | C | 12,06 | A |
| DS-031–034 | hygiene (see 17) | Low | L | E | 17 | — |

---

## 3. Master schedule

| # | Step | Name | DS | Diff | Risk | Type | Est. sessions | Status |
|---|------|------|-----|------|------|------|---------------|--------|
| 0 | **A0** | Verify/fix syncAllToStore failure | 002 | L–M | High if real | Correctness | 0.5–1 | [ ] |
| 1 | **A0b** | Pin invalidates search generation | 013 | L | Low | Correctness | 0.5 | [ ] |
| 2 | **A1** | Hygiene: dead code, docs, terms | 008p,017,027,005docs | L | Low | Hygiene | 1 | [ ] |
| 3 | **A2** | Dual-path map (no deletes) | 003,016 | L | None | Analysis | 1 | [ ] |
| 4 | **B0** | History split design (doc only) | 001 | M | None | Design | 0.5–1 | [ ] |
| 5 | **B1** | UIEffectPort | 007 | M | Med | Structure | 1–2 | [ ] |
| 6 | **B2** | History file split (no behavior) | 001,022 | M–H | Med | Structure | 2–3 | [ ] |
| 7 | **B3** | Tests migrate off `add` | 003 | M–H | Med | Tests | 2–4 | [ ] |
| 8 | **B4** | Isolate/remove legacy write | 003,016 | M | Med | Converge | 1–2 | [ ] |
| 9 | **C1** | Single filter source | 008 | M | Med | Domain | 1–2 | [ ] |
| 10 | **C2** | Index sync on UI delete | 009 | M | Med | Correctness | 1–2 | [ ] |
| 11 | **C3** | Single MatchEngine + empty short-circuit | 010,012,029 | M | Med | Structure | 2–3 | [ ] |
| 12 | **C4** | Batch limit deletes | 014 | L–M | Med | Persist | 1 | [ ] |
| 13 | **C5** | Move pin queries off entity | 015 | L | Low | Model | 0.5–1 | [ ] |
| 14 | **C6** | ItemID stability | 019,005 | M–H | High | Model | 2+ | [ ] |
| 15 | **D0** | Load ADR | 004 | M | Decision | Design | 0.5 | [ ] |
| 16 | **D1** | Implement load decision | 004 | H | High | Read path | 3–5 | [ ] |
| 17 | **D2** | Shrink MainActor hop | 011 | H | M–H | Perf/struct | 2–3 | [ ] |
| 18 | **D3** | Lossless FIFO ingest mailbox | 020 | M | Med | Perf | 1–2 | [x] `b754ac6` |
| 19 | **E1** | Intent port | 018 | M | Low | Boundary | 1 | [ ] |
| 20 | **E2** | Package moves (no behavior) | 026,034 | M | L–M | Hygiene | 1–2 | [ ] |
| 21 | **E3** | Timer / multiSelect | 024,028 | L | Low | Hygiene | 0.5 | [ ] |
| 22 | **E4** | Progressive DI vs shared | 006 | H | Med | Arch | ongoing | [ ] |
| 23 | **F** | Engineering gates | — | L–M | Low | Process | 1 | [ ] |

### Hard dependencies

```text
A0 before any syncAll/consume incremental changes
A2 → B3 → B4
B0 → B1 → B2
B2 before C3 recommended
C1 parallelizable with B (different files)
D0 → D1; D1 needs memory suite literacy
C6 after B4 (don't rekey IDs with dual writers)
```

---

## 4. Step details

### Wave A — Correctness & maps

#### A0 — DS-002

| | |
|--|--|
| **Read** | `02` A.14.2, `04` §7, `17` DS-002 |
| **Analyze** | Draw success / throw / empty-DB paths for `syncAllToStore` |
| **Fix direction** | On fetch error: record error, return; do not clear `all` |
| **Test** | Inject throwing fetchIdentifiers; assert all preserved |
| **Done when** | Failure ≠ empty; tests lock; DS-002 closed |
| **Forbidden** | Drive-by BinaryInsertion / search changes |

#### A0b — DS-013

| | |
|--|--|
| **Read** | `09`, `togglePin` |
| **Direction** | invalidate generation; re-search if query non-empty |
| **Test** | pin during in-flight search → stable final items/highlights |

#### A1 — Hygiene

| Sub | Action |
|-----|--------|
| A1.1 | Delete dead Clipboard helpers after re-rg |
| A1.2 | IngestPlan: document or remove |
| A1.3 | Point INDEX/architecture at HEAD re-checks |
| A1.4 | Glossary as term law |

#### A2 — Dual-path map (analysis deliverable)

Produce table:

| Dimension | Live actor | Legacy add | Test files |
|-----------|------------|------------|------------|
| Context | background | main | … |
| Transactions | 1 | multi | … |
| Dedup | SignatureIndex | full fetch | … |
| sessionLog | no | yes | … |
| UI update | consume | direct | … |

`rg` all `history.add` / `.add(historyItem`. **No deletions this step.**

---

### Wave B — Structure spine

#### B0 — Split design only

Target types in `04` §12 / `18`. Decide: keep type name `History` as facade? (**Yes recommended.**)

#### B1 — UIEffectPort

1. `rg AppState.shared Maccy/Observables/History.swift`  
2. Protocol: requestResize, closePopup, selectLead, highlightFirst, scrollTarget…  
3. Production adapter on AppState  
4. Tests: Spy/Noop  
5. Inject into History  

**Forbidden:** simultaneous file split.

#### B2 — File split, no behavior

Order: Legacy → Search → Reconcile → Mutations → (optional types later).  
One file per commit; CI green; message `refactor(history): split … no behavior change`.  
Optional: DS-012 dictionary same wave, separate commit.

#### B3 — Test migration

Helper `seedViaConsume` / store insert + snapshot + consume.  
sessionLog-only tests quarantined under LegacyAddTests until product WONTFIX.  
Perf factories: batch insert + load, not O(n²) add.

#### B4 — Remove/isolate legacy

Adapter test-only; deprecate/remove production `add`; document parity gap closed or WONTFIX.

---

### Wave C — Domain consistency

#### C1 — Single filter source

Shared UTI constants; Clipboard early gates reuse; document if fast path is strictly wider.

#### C2 — SignatureIndex sync

Options: (A) ingestor.noteRemoved (B) dirty rebuild (C) unified events. Prefer B then A.

#### C3 — MatchEngine

Shared pure match; empty query short-circuit; single oracle tests; id dictionary.

#### C4 — Batch trim

Align with actor oldest-unpinned-by-lastCopiedAt semantics; write difference down first.

#### C5 — Pin query off entity

#### C6 — ItemID stability study + possible schema

High risk; after B4 only.

Also schedule DS-025/030 as sub-tasks under C.

---

### Wave D — Read & hot paths

#### D0 — Load ADR (required)

Must answer: wire loader vs delete; does `all` need full decorators; search corpus full-set; pin sort; mainContext blob; success metrics.

#### D1 — Implement ADR in slices

#### D2 — MainActor hop reduction with RTF/HTML golden fixtures

#### D3 — Coalesce product decision

---

### Wave E–F — Boundaries & process

E1 Intent port · E2 package moves · E3 timer/multiselect · E4 stop shared sprawl · F line/dep/smell gates.

---

## 5. Local deep-dive checklist (copy per module)

```text
Module: ________
1. Declared vs actual responsibilities
2. Public API + callers (rg)
3. State: owner / writers / lifetime
4. Inbound data flow
5. Outbound data flow
6. Isolation (MainActor / actor / Task)
7. Error paths (try? / return / log)
8. Tests: have / missing / legacy-only
9. Bound DS IDs: ____
10. Smallest next slice: ____
```

### Recommended deep-dive order

1. syncAllToStore + insertIncrementally (A0)  
2. consume vs add (A2)  
3. Clipboard → ingest hops (C1/D2)  
4. performSearch/apply (C3)  
5. SignatureIndex lifecycle (C2)  
6. load + mainContext (D0)  
7. Decorator images (stable, low priority)  

---

## 6. Red lines

| Red line | Why |
|----------|-----|
| Weaken post-hash `==` in dataLikelyEqual | Collisions |
| Casual C++ UTF-8 changes | Truncation corruption |
| Split ingest multi-save | Data tears |
| Drop search generation / title equality | Wrong UI |
| mainContext.reset as memory fix | Breaks identity + jank |
| One PR: move + dedup + load | Unbisectable |
| Unmeasured search index | Premature |
| Generic EventBus | Hides deps |

---

## 7. Commit template

```text
fix(ds002): abort syncAllToStore on fetch failure

- DS: 002
- Global intent: prevent UI wipe on identifier fetch errors
- Files: …
- Tests: …
- Not done: …
- Playbook Step: A0
```

---

## 8. Progress table

| Step | Status | Date | Notes / new findings |
|------|--------|------|----------------------|
| A0 | | | |
| A0b | | | |
| A1 | | | |
| A2 | | | |
| B0–B4 | | | |
| C1–C6 | | | |
| D0–D3 | | | |
| E1–E4 | | | |
| F | | | |

**Backlog:**

| Temp ID | Description | Attach to |
|---------|-------------|-----------|
| | | |

---

## 9. Decision tree (this week)

```text
DS-002 verified?
  No → A0 (analysis + test + fix)
  Yes → A2 dual-path map done?
         No → A2
         Yes → Need structure?
                Hygiene only → A1
                Yes → B0 → B1 → B2 → B3 → B4
                     (C1 parallel OK)
                     then C2–C5; C6 careful
                     load only after D0 ADR
```

**If only one action this week:**  
- Safety → **A0**  
- Refactor prep → **A2**  
- Read-only → **`02` Flow A** line-by-line against source + fill A2 table  

---

## 10. Final acceptance checklist (all DS)

- [ ] DS-002 failure does not clear all  
- [ ] DS-001 History not one god file (or facade+partitions)  
- [ ] DS-003 single production write path; tests not on legacy  
- [ ] DS-004 load ADR landed (wire or delete)  
- [ ] DS-005 identity invariants tested  
- [ ] DS-006 shared not expanding  
- [ ] DS-007 no AppState.shared inside History  
- [ ] DS-008 single rules; dead helpers gone  
- [ ] DS-009 index sync or rebuild  
- [ ] DS-010 single MatchEngine  
- [ ] DS-011 measured hop / WONTFIX recorded  
- [ ] DS-012 O(1) id resolve  
- [ ] DS-013 pin/search consistent  
- [ ] DS-014 batch trim  
- [ ] DS-015 entity free of Storage  
- [ ] DS-016 adapter non-prod  
- [ ] DS-017 IngestPlan cleaned  
- [ ] DS-018 Intent port  
- [ ] DS-019 ItemID strategy documented  
- [x] DS-020 lossless FIFO coalesce decision + implementation recorded (`b754ac6`)
- [ ] DS-021–034 addressed or explicitly deferred with owner  

When all checked: structure campaign phase-complete (memory BS targets remain separate).

---

## 11. Compliance

Read-only analysis + documentation. No claim that production issues are fixed until you implement and CI-verify.
