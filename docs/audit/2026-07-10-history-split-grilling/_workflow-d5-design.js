export const meta = {
  name: 'd5-commit-design',
  description: 'Design + adversarially verify the D5 fix (actor commit O(rows) fetch+sort per copy → incremental), preserving trim invariants and handling pin-drift',
  phases: [
    { title: 'Design', detail: '3 independent fix designs (incremental-tail / bounded-fetch / minimal-risk-or-defer)' },
    { title: 'Verify', detail: 'each design attacked on trim-correctness + pin-drift' },
  ],
}

const CONTEXT = `
PROJECT: Maccy (macOS clipboard manager, Swift 6.0 strict concurrency, SwiftData). No local toolchain; CI on GitHub Actions is the gate.

THE PROBLEM (D5 / NEW-ingest-dualpath-1): The ingest actor's \`commit()\` in \`Maccy/Ingest/ClipboardIngestor.swift\` does this EVERY copy:
  let descriptor = FetchDescriptor<HistoryItem>(predicate: #Predicate { $0.pin == nil }, sortBy: [SortDescriptor(\\.lastCopiedAt, order: .reverse)])
  var unpinned = (try? modelContext.fetch(descriptor)) ?? []
  // remove dup from unpinned, then delete unpinned.dropFirst(limit - 1) (the oldest tail), then insert the new item
At n=1000 this FAULTS all 1000 unpinned @Model rows + sorts them, every copy.

MEASURED (CI run 29061409815, perf-text shard, test testGIngestPerCopy_N1000): per-copy ingest = **51.90 ms avg / 83.93 ms max at n=1000**; mainThread maxGap only 0.080s → ~48ms is OFF-main (the commit's fetch+sort). This DOMINATES per-copy cost (the main-side consume is 3.33ms post-D4). For comparison, D4's \`fetchIdentifiers\` (ids-only, no faulting) was "cheap" — so the cost is the FULL-ROW FAULTING + sort, not the query itself.

THE CONSTRAINTS (non-negotiable):
1. TRIM SEMANTICS MUST BE PRESERVED EXACTLY. The existing test \`MaccyTests/BackgroundClipboardIngestorTests.testCommitPreservesDistinctItemsAndCountsDuplicateOnMerge\` guards a specific invariant: the dup is removed from the unpinned count BEFORE the \`limit-1\` trim is applied (so a merge that would overflow doesn't evict a distinct item). Any D5 change MUST preserve: (a) dup-removed-before-count, (b) trim oldest-unpinned-by-lastCopiedAt beyond limit-1, (c) the dup+excess all deleted + new item inserted in ONE transaction + ONE save (the single-transaction invariant — DO NOT split), (d) the dedup index (\`maintainDedupIndex\`) stays in sync (it gets the deleted ItemIDs + the inserted item).
2. PIN-DRIFT: pin changes happen on the MAIN actor (\`History.togglePin\` → \`persistence.save()\`), NOT in this actor. The actor has NO notification of pin changes. Today's per-copy fetch is FRESH (always reflects current pin state). An incremental/in-memory structure in the actor would be STALE after a main-side pin change → could evict a just-PINNED item (DATA LOSS — a pinned item deleted). The design MUST NOT introduce this hazard. Acceptable: re-validate pin status on the eviction path (O(1) targeted check) with fallback to the full fetch if stale; or a design that provably cannot evict a pinned item.
3. structure ≠ behavior: D5 is a behavior (perf) change — own PR, no file split.
4. Single-transaction invariant: the dup-delete + trim + insert stay in one \`modelContext.transaction { }\` + one save.
5. No new abstractions that are hollow (B1 lesson): the change must deliver measured perf, not relocate work.

READ TO GROUND YOUR DESIGN:
- Maccy/Ingest/ClipboardIngestor.swift (the actor: commit() ~line 477, ingest(), findDuplicate(), maintainDedupIndex(), ensureDedupIndexInitialized()).
- MaccyTests/BackgroundClipboardIngestorTests.swift (testCommitPreservesDistinctItemsAndCountsDuplicateOnMerge — the invariant to preserve; other commit/trim tests).
- Maccy/Observables/History.swift limitHistorySize() (the main-side trim the actor mirrors — same eviction semantics).
`

const DESIGN_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['lens', 'approach', 'exactChange', 'bigOhBeforeAfter', 'trimInvariantsPreserved', 'pinDriftHandling', 'risks', 'testsNeeded', 'verdict'],
  properties: {
    lens: { type: 'string' },
    approach: { type: 'string', description: 'The mechanism in 2-3 sentences' },
    exactChange: { type: 'string', description: 'The concrete change to commit() — what it fetches/computes/deletes instead. Be precise about the SwiftData calls (fetchCount? fetchLimit? predicate delete? in-memory structure?).' },
    bigOhBeforeAfter: { type: 'string', description: 'Per-copy complexity: before (O(rows) full fault) → after (what?)' },
    trimInvariantsPreserved: { type: 'string', description: 'How each of (a) dup-before-count (b) oldest-by-lastCopiedAt trim (c) single-transaction (d) dedup-index-sync is preserved. Quote the specific logic.' },
    pinDriftHandling: { type: 'string', description: 'How the design CANNOT evict a just-pinned item. If it can, say so honestly (risk).' },
    risks: { type: 'string' },
    testsNeeded: { type: 'string', description: 'The edge-case tests required (ties at the threshold, dup-is-the-newest, pin-change-between-ingests, count-exactly-at-limit, etc.)' },
    verdict: { type: 'string', description: 'implement / defer / too-risky' },
  },
}

const VERIFY_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['target', 'preservesTrimInvariants', 'pinDriftSafe', 'singleTransactionHeld', 'missedEdgeCase', 'survives', 'fatalFlaw'],
  properties: {
    target: { type: 'string' },
    preservesTrimInvariants: { type: 'boolean', description: 'true if dup-before-count + oldest-trim + single-txn + dedup-sync ALL hold' },
    pinDriftSafe: { type: 'boolean', description: 'true if the design PROVABLY cannot evict a just-pinned item' },
    singleTransactionHeld: { type: 'boolean' },
    missedEdgeCase: { type: 'string', description: 'an edge case the design under-weighted (ties, dup-newest, count==limit, concurrent pin change, etc.)' },
    survives: { type: 'boolean', description: 'true if, after your attack, the design is correct AND captures the perf win' },
    fatalFlaw: { type: 'string', description: 'the single biggest correctness risk, or "none"' },
  },
}

const LENSES = [
  { key: 'incremental-tail', angle: 'INCREMENTAL TAIL. Maintain an in-memory ordered (by lastCopiedAt) structure of unpinned items in the actor; insert the new item; evict the oldest tail in O(log n) WITHOUT fetching all. CONFRONT pin-drift head-on: how do you guarantee you never evict a just-pinned item when the actor gets no pin-change notification? (Re-validate the eviction candidate\'s pin via a targeted O(1) fetch? Invalidate the tail on... what?) Specify the exact pin-safety mechanism. If you cannot make it provably safe, say verdict=too-risky.' },
  { key: 'bounded-fetch', angle: 'BOUNDED FETCH. Keep the per-copy FETCH but make it O(limit) not O(rows): use fetchCount (cheap, no faulting — like D4\'s fetchIdentifiers) to learn IF a trim is needed, then fetch only the newest `limit` unpinned (fetchLimit) to find the eviction threshold, and predicate-delete the older tail. Preserves the fresh-per-copy pin view (no drift). Work out the dup-before-count interaction (the dup is deleted in the same txn — does the count exclude it? does the predicate-delete double-delete it?). Specify the exact SwiftData calls.' },
  { key: 'minimal-or-defer', angle: 'MINIMAL-RISK / DEFER. You believe a full D5 (trim-logic rewrite) is too risky for the perf win, OR that a minimal safe change captures most of it. Argue either: (a) a MINIMAL change (e.g., fetch only identifiers/timestamps not full rows, or fetchCount-gated) that is obviously safe and captures a chunk of the 48ms without touching trim semantics — specify it; or (b) DEFER D5 — the 52ms is real but the trim-logic rewrite risk (data loss) outweighs it, and a smaller/safer lever exists. Be honest about which.' },
]

const designs = await pipeline(
  LENSES,
  (lens) => agent(
    `${CONTEXT}\n\n=== YOUR LENS: ${lens.key} ===\n${lens.angle}\n\nRead the files. Design the change precisely. The trim invariants and pin-drift safety are ABSOLUTE — if your design can\'t guarantee them, say so (verdict=too-risky) rather than hand-waving.`,
    { label: `design:${lens.key}`, phase: 'Design', schema: DESIGN_SCHEMA }
  ),
  (design, lens) => agent(
    `${CONTEXT}\n\n=== ADVERSARIAL VERIFY ===\nA colleague proposed this D5 fix:\n\n${JSON.stringify(design, null, 2)}\n\nAttack it as a correctness reviewer whose #1 fear is EVICTING A PINNED ITEM (data loss) or BREAKING THE TRIM INVARIANTS (dup-before-count, oldest-by-lastCopiedAt, single transaction, dedup-index sync). Check each invariant literally against the actor code. Find the edge case the design missed (a tie at the eviction threshold; the dup being the newest item; count exactly == limit; a pin change landing between the count and the delete; the predicate-delete double-deleting the dup). Then: does it SURVIVE — correct AND captures the perf win? Read the files to verify claims (especially commit() and testCommitPreservesDistinctItemsAndCountsDuplicateOnMerge).`,
    { label: `verify:${lens.key}`, phase: 'Verify', schema: VERIFY_SCHEMA }
  ).then((v) => ({ lens: lens.key, design, verify: v }))
)

return {
  total: designs.filter(Boolean).length,
  designs: designs.filter(Boolean).map(d => ({
    lens: d.lens,
    verdict: d.design.verdict,
    bigOh: d.design.bigOhBeforeAfter,
    pinSafe: d.verify.pinDriftSafe,
    invariantsHold: d.verify.preservesTrimInvariants,
    survives: d.verify.survives,
    fatalFlaw: d.verify.fatalFlaw,
    approach: d.design.approach,
    exactChange: d.design.exactChange,
    missedEdgeCase: d.verify.missedEdgeCase,
    testsNeeded: d.design.testsNeeded,
  })),
}
