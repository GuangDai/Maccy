# 03 — Severity Recalibration & Glossary/Location Corrections

**Baseline:** HEAD `6cd37c8` · Two parts: (A) why six findings were down-graded and two up-graded; (B) the location/term errors the verification corrected.

---

## A. Severity recalibration (rationale)

The audit scores *mechanism presence*. The verification scores *realized impact*. The gap is where severity inflates.

### Down-graded (overstated)

**DS-002 — Critical → High.** The wipe is real and silent (no `recordPersistenceError`), but: (1) **no `@Model` rows are deleted** — `all` is in-memory only; the store is intact; (2) it **self-heals**: the wipe empties `items`, so `ContentView.task`'s `if items.isEmpty` / `prewarm`'s `guard items.isEmpty` re-trigger `load()`, which rebuilds from the intact store. The adversarial skeptic's key nuance: this self-heal **fails exactly when it matters** — if the store is *genuinely* throwing, `load()` inside `prewarm` also throws and is swallowed by `try?` (`AppState:101`), leaving the panel empty with **no diagnostic**. That silent-masking character (not data destruction) is what holds the finding at High rather than dropping it to Medium. Critical would require permanent data loss, which does not occur.

**DS-006 — High → Medium.** The 171/26 (actually 175/26 occurrences) singleton-bus figure is real, but the impact is purely structural/testability — there is **no runtime or correctness consequence**. It belongs in the same tier as other structural debt, not above it.

**DS-016 — Medium → Low.** "Residual" overstates it. `MainActorIngestorAdapter` has **zero instantiation sites** repo-wide; only its static `historyItem(from:)` helper is used (in one test). The `ingest(_:)` method and the `ClipboardIngestor` conformance are **fully dead**, so the "nil-event mis-wiring risk" describes dormant code, not a live hazard.

**DS-017 — Medium → Low.** `IngestPlan` has exactly two repo references: its definition (`Dtos.swift:110`) and `DtoTests.requireSendable`. Zero production constructions. It is a nominal type, not a "fake pipeline abstraction" with real surface.

**DS-019 — Medium → Low (refuted as cross-relaunch risk).** The mechanism is real (`itemID(for:)` feeds `String(describing: persistentModelID)` into the FNV-1a fold). But the asserted consequence — keys breaking across relaunch on a macOS format change — **requires ItemIDs to survive a relaunch**, and nothing persists them: neither `@Model` has an ItemID/UUID column, and the entire dedup index is in-memory actor state **rebuilt from the store via `ensureDedupIndexInitialized` on the first ingest of every process**. On relaunch every key is re-derived with whatever format *this* macOS yields, so old and new items stay internally consistent. What remains is a latent reliance on an undocumented description format — Low.

**DS-025 — Medium → Low.** The no-`save()`-before-predicate-delete structure is real, but the trigger is **dormant**: the sole main-context insert (`History.swift:36`) saves immediately (`:37-38`); the live ingestor writes to a **separate** `ModelContext(modelContainer)` and commits atomically in `commit`. No production path leaves a pending insert on the main context for the predicate delete to leak. Real structural fragility, dormant trigger → Low.

**DS-029 — Medium → Low.** Fire-and-forget corpus tasks can lag one item; the code documents this, it self-corrects, and the trigger is narrow.

### Up-graded (understated)

**DS-008 — Low, but the dead surface is larger.** Beyond the three enumerated helpers, `filteredTypes` (`:278-292`), the `supportedTypes`/`disabledTypes` cascade (`:44-61`), and the `ignoredRegexps` `NSCache` (`:17-21`, used only by the dead `shouldIgnore(item)`) are all dead. Severity stays Low (hygiene, no runtime impact), but the cleanup is bigger than the audit implies.

**DS-028 — Low/Med → High (cleanup value).** The switch itself is Low, but it gates a **~250 LOC unreachable paste-stack/multi-select subtree** (`NEW-singletons-intents-misc-1`). The value of removing it is High.

---

## B. Location & glossary corrections

### B.1 Location errors (wrong file / line range)

| Audit said | HEAD truth | Affects |
|------------|------------|---------|
| `SwiftDataHistoryPersistence` lives in `Maccy/Persistence/SwiftDataHistoryPersistence.swift` | **No such file.** `SwiftDataHistoryPersistence` + the `HistoryPersistence` protocol are defined **inline in `Maccy/Observables/History.swift:12-91`**. The only file under `Maccy/Persistence/` is `Storage+Background.swift`. | DS-022, DS-025, glossary, `06-module-models` |
| `deleteUnpinned` is in `SwiftDataHistoryPersistence.swift` | Inline, `History.swift:49-62` (14 lines) | DS-025 |
| ItemID double FNV-1a fold at `Dtos.swift:177-180` | `:177-180` is the `itemID(for:)` **wrapper** (`String(describing:)`). The **fold itself** (offset basis `0xcbf29ce484222325`, prime `0x00000100000001b3`, two seeds, UUID packing) is at **`Dtos.swift:186-217`**. | DS-019, glossary §2 |
| `syncAllToStore` at `420-433` | `420-441` (destructive loop `425-434`; method ends `441`) | DS-002 |
| `MainActorIngestorAdapter` at `ClipboardIngestor.swift:14-36` | `14-37` (off-by-one, missing closing brace) | DS-016 |

### B.2 Glossary / term corrections

| Term (audit) | Verified |
|--------------|----------|
| **Singleton bus: "171 matches across 26 files"** | **175 word-boundaried occurrences** across 26 files (rg `\b(AppState|History|Storage|Clipboard)\.shared\b`). 175 vs 171 = occurrences-vs-lines (some lines hold two refs). Also: the figure counts **only 4 of the 8** shared symbols the glossary's own §5 table lists (omits `VisibilityTracker`/`MemoryGovernor`/`ApplicationImageCache`/`defaultImageProcessor`). Label it "four named singletons," not the whole bus. |
| **"Cold load" alias** | Accurate but **not side-effect-free**: `load()` calls `limitHistorySize(to:)` (`:275`) which **deletes overflow rows** (`unpinned[maxSize...].forEach(delete)` @292). A "load" that mutates the store. |
| **"Cold load" alias** | Should **cross-link DS-022**: `load()` uses `Storage.shared.context.fetch` directly (not the persistence port), so a fake `HistoryPersistence` cannot intercept the cold-load path — that is the dual-channel gap. |
| **"Legacy add"** | Accurate, but add: (1) `findSimilarItem` is **`private`** (`History.swift:742`), reachable only via `add`; (2) the actor's own class doc (`ClipboardIngestor.swift:74-80`) names the exact parity gap — **no `sessionLog`/`isModified` modification-merge on the actor** (deliberate). |
| **"Live ingest" alias** | Omits the **`MainActor.run` hop** inside `ingest` (DS-011): the alias reads as end-to-end off-main, but `ingest` hops to main once per call for filter/title/body/limit (NSAttributedString/Defaults affinity). |
| **`MainActorIngestorAdapter`** | Not just "not production-wired" — **fully dead**: 0 instantiation sites repo-wide; only the static `historyItem(from:)` helper is used (one test). |
| **SignatureIndex rebuild** | "**stale entries persist until process restart or rebuild**" → there is **no rebuild trigger**. `dedupIndexInitialized` is set `true` on the first ingest (`ClipboardIngestor.swift:352`) and **never reset**; only a process restart clears stale entries. Sharpens DS-009. |
| **`filteredTypes`** | `07-module-clipboard.md:61` says "private; not all used on live path." Actually **`internal` (no `private`)** and **zero call sites anywhere** (dead, not partially-used). Its sole caller `contents(from:)` was removed in `9cb7d3f`. |
| **`Clipboard.contents(from:)`** | Does **not exist** in HEAD (removed `9cb7d3f`), yet **5 doc comments** still reference it as live (`IngestFilter.swift:7,64`; `ClipboardIngestor.swift:134,440`; `IngestFilterTests.swift:6`). `IngestFilter.swift:64` frames the whole module as its "twin." Doc rot. |
| **ItemID "double FNV-1a fold"** | Accurate (`Dtos.swift:186-198`). **Distinguish** from the **xxh3 content dedup fingerprint** (`HistoryItemContent.fingerprint`). `CLAUDE.md`'s "FNV-1a retained but superseded" refers to the legacy *content*-hash path, **not** ItemID — the glossary correctly keeps them separate, but readers conflate them. |
| **`HistoryItem.init(contents:)`** | The baseline init body self-assigned `firstCopiedAt`/`lastCopiedAt` (`:112-116`) — no-op (no such params; RHS = the property's own default). **Resolved `91d76b8`:** both lines were deleted. |

---

## C. What this means for the audit suite

1. **The flow traces (`02`) and findings catalog (`17`) remain the best design map** — their *mechanisms* held up under adversarial re-reading. Use them; just apply the severity column from `01` above.
2. **The playbook (`19`) Wave A should be re-ordered** per `00` §4: insert `NEW-dedup-ids-1` at the top and the generation bug-class; the "incremental" perf items move up.
3. **Two module docs need a one-line fix each:** `06-module-models` (SwiftDataHistoryPersistence location) and `07-module-clipboard` (`filteredTypes` status). Low priority, but they currently mislead.
4. **The glossary should be patched** with the B.2 corrections — especially "no rebuild trigger" (DS-009) and "Cold load is not side-effect-free."
