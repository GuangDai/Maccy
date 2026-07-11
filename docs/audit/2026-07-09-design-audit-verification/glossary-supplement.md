# Glossary Supplement — Terms Sharpened During Grilling

**Baseline:** HEAD `6cd37c8` · Supplements [`../2026-07-09-design-structure-audit/glossary.md`](../2026-07-09-design-structure-audit/glossary.md). New and corrected terms that crystallized during verification.

---

## New terms (concepts the audit's glossary lacked)

| Term | Meaning | Why it matters |
|------|---------|----------------|
| **Search-generation discipline** | The invariant that *any* mutation changing `all`'s contents or order must cancel the in-flight search (`invalidateInFlightSearch()` / bump `searchGeneration`) before the stale generation's `applySearchResults` can run. | The audit treated DS-013 (togglePin) as a single bug. Verification found it is a **class** — `load()` and `select()` have the same omission. The term names the structural cause: discipline is per-call-site, not centralized. |
| **Incremental-but-O(n) path** | A path *labeled* "incremental" (per-copy, avoid full work) that is nevertheless linear in total history size on every invocation. | `syncAllToStore` (main, every copy) and `commit`'s unpinned fetch+sort (actor, every copy) are both O(rows). The "incremental per-copy reconcile" roadmap label hides this. |
| **Silent dedup disable** | The failure mode where `ensureDedupIndexInitialized` swallows a first-ingest fetch error and flips `dedupIndexInitialized = true` with an empty index, turning off dedup for the whole session with no log. | `NEW-dedup-ids-1`. Distinct from a dedup *miss* — this is dedup *off*. |
| **Mutating read** | A query whose stated purpose is to read (dedup lookup, load) but which writes as a side effect. Candidate fingerprint backfill was moved out of lookup on 2026-07-11; the load-side case remains. | `NEW-ingest-dualpath-2` resolved by `f9f0e85`; `NEW-storage-load-models-2` and the "Cold load is not side-effect-free" correction remain. |
| **Dead-feature subtree** | A coherent, non-trivial code surface (model + extension + views + key handling) rendered wholly unreachable by a single always-false gate, yet not marked deprecated. | `multiSelectionEnabled = false` gates ~250 LOC of paste-stack/multi-select (`NEW-singletons-intents-misc-1` / DS-028). |

---

## Corrections to existing glossary entries

| Glossary entry | Correction |
|----------------|------------|
| **Singleton bus count** (§5) | "171 matches" → **175 word-boundaried occurrences**; and the regex counts **only 4 of the 8** shared symbols listed in §5's own table. Re-label as "four named singletons." |
| **Cold load** (§4 alias) | Add: **not side-effect-free** — calls `limitHistorySize(to:)` which deletes overflow rows. And **cross-link DS-022**: `load()` bypasses the persistence port (`Storage.shared.context.fetch` direct), so it is not interceptable by a fake `HistoryPersistence`. |
| **Live ingest** (§4 alias) | Add: **not end-to-end off-main** — `ingest` hops to `MainActor.run` once per call for filter/title/body/limit (DS-011). |
| **Legacy add** (§1) | Add: `findSimilarItem` is `private` (reachable only via `add`); the actor's class doc names the parity gap (no `sessionLog`/`isModified` modification-merge on the actor). |
| **SignatureIndex rebuild** (implicit in DS-009 text) | **Audit baseline:** no rebuild trigger. **Current:** UI delete/clear forwards batched removal/reset events; a full clear marks the index uninitialized for a safe next-ingest rebuild (`c6afcbe`). |
| **ItemID** (§2) | Fold location: `Dtos.swift:186-217` (the `:177-180` site is the wrapper). Keep distinct from the **xxh3 content fingerprint** — `CLAUDE.md`'s "FNV-1a superseded" refers to the legacy *content* hash, **not** ItemID. |
| **`MainActorIngestorAdapter`** | "Not production-wired" → **fully dead** (0 instantiation sites; only static `historyItem(from:)` used in one test). |

---

## Identifier/signature map (verified HEAD locations)

```text
PersistentIdentifier  SwiftData-assigned; stable across relaunch; the ONLY true persistence identity.
ItemID = UUID         Double FNV-1a fold of String(describing: persistentModelID).
                      Fold: Maccy/Ingest/Dtos.swift:186-217   (wrapper itemID(for:) :178-180)
                      NOT persisted in any @Model → rebuilt every process (why DS-019 is Low).
Decorator id = UUID() Fresh per HistoryItemDecorator init (Maccy/Observables/HistoryItemDecorator.swift:47).
                      Used for: SearchMatchDTO.id, selection, VisibilityTracker, SwiftUI Identifiable.
                      Never stable across re-decorate (merge/load) → corpus must remove(old) then insert(new).

Index signature       SignatureDTO / ContentSignatureEntry { type, size, fingerprint? }
                      Registered by snapshot(of:)  Dtos.swift:141-148
                      Queried by  findDuplicate     shared `signatureDTO(of:)` projection (`10f8d90`)
Containment signature HistoryItemEngine.Signature (value bytes) — AUTHORITATIVE for supersedes/dataLikelyEqual.
```

---

## Invariants sharpened by verification

1. **Stale SignatureIndex entries cannot cause a false-positive dedup** — `supersedes` is containment over `self.contents`, so a no-contents shell (what `model(for:)` returns for a store-deleted PID) structurally cannot match. *(Leans on empirically-documented SwiftData shared-store delete propagation, not a formal guarantee.)*
2. **The dedup index is process-scoped, not store-scoped** — it is rebuilt from the store on first ingest and never rebuilt thereafter; there is no incremental repair path.
3. **`load()` is a mutating read** — it can delete rows via `limitHistorySize`. "Load" in this codebase is not idempotent-with-respect-to-the-store.
4. **Error swallowing is the dominant silent-failure pattern** — `syncAllToStore` (`try? ?? []`), `ensureDedupIndexInitialized` (`try? ?? []`), `ContentView`/`prewarm` (`try? await load`), and the fire-and-forget ingest (`IngestResult` discarded) all collapse failures to empty/silent. Four distinct sites, one theme.
