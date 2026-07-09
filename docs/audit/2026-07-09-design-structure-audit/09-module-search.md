# 09 — Module: Search

**Files:** `Search.swift` (217), `SearchActor.swift` (265), `SearchDTOs.swift` (68), `TextLimits.swift`, `SearchVisibility.swift`, `HighlightMatch.swift` + orchestration in `History`  
**Baseline:** HEAD `6cd37c8` · Flow C in `02`

---

## 1. Dual implementation (DS-010)

| | Legacy `Search` | `SearchActor` |
|--|-----------------|---------------|
| Isolation | `@MainActor class` | `actor` |
| Input | `[HistoryItemDecorator]` | owned corpus / `[SearchCorpusItem]` |
| Output | `SearchResult` holding decorator refs | `SearchMatchDTO` (id + ranges) |
| Full-text body | title-centric | title first then body (`searchText` projection) |
| Production use | **empty query only** | **non-empty query** |
| Tests | SearchTests | SearchActorTests, FullText* |

---

## 2. Production non-empty path

See `02` Flow C. Corpus owned by actor; keystroke sends query+mode only.

### Match algorithms (actor)

| Mode | Notes |
|------|-------|
| exact | Character offsets via `distance`; `inBody` flag |
| fuzzy | Fuse 0.7; truncated haystacks; title-first sort |
| regexp | unsafe nested quantifier reject; empty match `0..<0` valid |
| mixed | short-circuit tiers; skip regexp if no metacharacters |

`TextLimits` is the single truncation source of truth (keep).

---

## 3. Orchestration bugs / debts

| ID | Issue |
|----|--------|
| DS-010 | Dual engines |
| DS-012 | `all.first { id }` O(n) |
| DS-013 | togglePin no generation bump |
| DS-029 | fire-and-forget corpus updates |

Mode enum + localization live on `Search` type; Actor depends on `Search.Mode` — coupling of UI strings to engine type.

---

## 4. Preview highlight coupling

Body matches → `setPreviewHighlight`; title unhighlighted. Preview views consume ranges (incl. NSTextView path for deep matches). Coordinated with BS-5 redesign docs.

---

## 5. Performance assumptions

- n ≈ Defaults history size (hundreds typical)  
- body capped by searchBodyLimit  
- Fuse is known hotspot (prior perf notes)  
- No index (ADR: measure first)  

---

## 6. Recommendations

1. Extract `MatchEngine` used by Actor (+ tests as oracle).  
2. Empty query: `items = all` + clear highlights; drop legacy engine from production path.  
3. Dictionary id→decorator on History list state.  
4. Pin/reorder invalidates or re-runs search.  

**Confidence:** High.
