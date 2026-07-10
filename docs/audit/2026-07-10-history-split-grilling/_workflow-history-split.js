export const meta = {
  name: 'history-split-adversarial-panel',
  description: 'Adversarial 4-judge panel on how to split History.swift next, each grilled for hollow-ness (the B1 lesson)',
  phases: [
    { title: 'Propose', detail: '4 independent split proposals from distinct lenses' },
    { title: 'Attack', detail: 'each proposal attacked for hollow-ness by a skeptic' },
  ],
}

// Hard context every judge + skeptic must obey. Embedded so they don't rediscover it.
const CONTEXT = `
PROJECT: Maccy (macOS clipboard manager, Swift 6.0 strict concurrency, AppKit+SwiftUI+SwiftData). No local toolchain; CI on GitHub Actions is the gate.

THE QUESTION: What is the right NEXT step for splitting Maccy/Observables/History.swift (989 LOC god object)?

THE NON-NEGOTIABLE CONSTRAINT — "avoid hollow / surface / meaningless work":
A prior attempt (B1 "UIEffectPort") was REVERTED on 2026-07-10 as hollow: its AppState-backed adapter still called AppState.shared in every method, so the History→AppState coupling was RELOCATED not removed — runtime unchanged, testability not unblocked. The user's locked principle: a structural change must deliver CONCRETE value — (a) a correctness fix, (b) a measured perf win, (c) a test that was actually blocked, or (d) clear a hard gate that blocks other work. Moving code between files, wrapping a singleton in a protocol, or relocating coupling WITHOUT one of those is "脱裤子放屁" (hollow) and must be rejected.

HARD FACTS (verified against HEAD — read files to confirm):
- History.swift = 978 lines. SwiftLint .swiftlint.yml: file_length error=1000 AND type_body_length error=1000. So the file is 22 lines under a HARD CI error. Any nontrivial addition trips it. NOTE: SwiftLint measures each extension declaration separately from the class, so a pure extension-split (extension History {} in new files, NO new types) clears BOTH gates. Therefore the lint gate alone does NOT force real type extraction.
- History is @MainActor @Observable class, conforms to ItemsContainer (associatedtype Item) and HistoryRef. @Observable does NOT compose trivially — extracting observed state (e.g. searchQuery) into a subtype breaks view observation unless the subtype is itself @Observable and exposed. This is a real cost of real-type-extraction.
- 5 direct Storage.shared.context sites (DS-022 "dual IO channel"): load() fetch@210, insertIncrementally model(for:)@337, syncAllToStore fetchIdentifiers@403, reconcileWithStore fetch@434, mergeDuplicateIfNeeded delete@497. The other IO (insert/delete/save/deleteUnpinned/deleteAll/fetchAll/count) goes through the HistoryPersistence protocol (HistoryPersistence.swift). Routing the 5 direct sites through HistoryPersistence is the one structural change with standalone concrete value: makes the port intercept everything (testability), and is the prerequisite for D1 windowed-load.
- 22 AppState.shared sites: popup.needsResize, popup.close, navigator.select, navigator.scrollTarget, navigator.isMultiSelectInProgress, navigator.highlightFirst. These are the coupling B1 tried and failed to fix. Real fix = INVERSION (History publishes effect intents; UI subscribes), NOT a singleton-wrapping port.
- Legacy add() path (add/findSimilarItem/mergeDuplicateIfNeeded/sessionLog/isModified/insertDecorator ~80 LOC) is DEAD IN PROD (reachable only via MainActorIngestorAdapter which has 0 instantiation sites). Live ingest = actor → History.consume → reconcile. The roadmap sequences: B3 migrate tests off add, B4 delete legacy add.

ROADMAP CONTEXT (docs/audit/2026-07-10-master-roadmap.md): After the B1 revert, the roadmap's OWN near-term recommendation pivoted to D4 (syncAllToStore O(n)→O(deleted) per-copy perf — concrete measured win) as "the right kind of next step: concrete value, not ceremony." Wave B structure is labeled "enabling" not "value." Red lines: NO generic EventBus, NO search index without measured need, NO repository pyramid, NO full DDD package tree in one migration, structure≠behavior in the same PR, don't move dirs+dedup+load in one PR.

READ THESE TO GROUND YOUR PROPOSAL (do not rediscover):
- Maccy/Observables/History.swift (the file)
- Maccy/Observables/HistoryPersistence.swift (the port)
- docs/audit/2026-07-10-master-roadmap.md (Waves B/D, red lines, decision forks)
- docs/audit/2026-07-09-design-audit-verification/00-executive-verdict.md and 02-new-findings.md
- docs/audit/2026-07-09-design-structure-audit/04-module-history.md (§12 target boundary) and 19-master-playbook.md (Wave B)
`

const PROPOSAL_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['lens', 'recommendedNextStep', 'concreteValueDelivered', 'hollowTest', 'granularity', 'order', 'respectsRedLines', 'biggestRisk', 'oneLine'],
  properties: {
    lens: { type: 'string' },
    recommendedNextStep: { type: 'string', description: 'One of: split-extension-only / split-extension-plus-DS022-close / real-type-extraction-minimal / d4-first-then-split / defer-split-until-forced / something-else-named' },
    concreteValueDelivered: { type: 'string', description: 'The concrete value. MUST be one of: correctness / measured perf / test-unblocked / clears-hard-gate. Be specific.' },
    hollowTest: {
      type: 'object', additionalProperties: false,
      required: ['relocatesCoupling', 'changesRuntime', 'unblocksATestThatExistsToday', 'clearsLintWall', 'wouldHaveBeenHollowAsB1'],
      properties: {
        relocatesCoupling: { type: 'boolean', description: 'true if coupling is merely moved (like B1)' },
        changesRuntime: { type: 'boolean' },
        unblocksATestThatExistsToday: { type: 'boolean', description: 'false if it only unblocks a future/hypothetical test' },
        clearsLintWall: { type: 'boolean' },
        wouldHaveBeenHollowAsB1: { type: 'boolean', description: 'true if an engineer would call this the same kind of hollow as the reverted B1' },
      },
    },
    granularity: { type: 'string', description: 'extension files vs new types; how many pieces; names; observation-binding handling' },
    order: { type: 'string', description: 'which piece first and why (Legacy/Search/Reconcile/Mutations or other)' },
    respectsRedLines: { type: 'string', description: 'how it avoids EventBus/DDD-tree/structure≠behavior/etc.' },
    biggestRisk: { type: 'string' },
    oneLine: { type: 'string' },
  },
}

const SKEPTIC_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['proposalVerdict', 'isHollow', 'hollowReasoning', 'missedCost', 'whatWouldMakeItConcrete', 'survives'],
  properties: {
    proposalVerdict: { type: 'string', description: 'the lens being attacked' },
    isHollow: { type: 'boolean', description: 'true if it fails the concrete-value test (B1 analog)' },
    hollowReasoning: { type: 'string' },
    missedCost: { type: 'string', description: 'a cost the proposal underweighted — observation binding, test churn, PR count, merge conflicts with C/D waves, etc.' },
    whatWouldMakeItConcrete: { type: 'string', description: 'the minimal change that would convert this from hollow to concrete-value' },
    survives: { type: 'boolean', description: 'true if, after your attack, the proposal still delivers concrete value worth doing now' },
  },
}

const LENSES = [
  { key: 'minimal-gate-clearer', angle: 'MINIMALIST. You believe the only justified move right now is the smallest change that clears the file_length wall and nothing more. Argue why anything beyond that is premature. Design the minimal extension-split. Be ruthless about what you EXCLUDE and why (DS-022, AppState, search).' },
  { key: 'value-bundler', angle: 'VALUE-BUNDLER. You believe a behavior-neutral file move alone is hollow; the split is only worth doing if it BUNDLES the one structural change with standalone concrete value — closing DS-022 (route the 5 direct Storage.shared.context sites through HistoryPersistence) in the same wave. Design split + DS-022-close as a sequence of refactor PRs. Justify why bundling is structure-not-behavior.' },
  { key: 'depth-extractor', angle: 'EXTRACTOR. You believe extension-splits are cosmetic and the real win is extracting the 5-7 target types from 04§12 (HistoryListState / StoreProjector / SearchSession / Mutations / LegacyWriter). Design the minimal FIRST real-type-extraction and the observation-binding solution. You MUST confront: is this "full DDD package tree in one migration" (a red line)? Is there a concrete test unblocked TODAY, or only future?' },
  { key: 'roadmap-skeptic', angle: 'ROADMAP SKEPTIC. You believe splitting History.swift NOW is the wrong priority — the roadmap pivoted to D4 (concrete per-copy perf) for a reason. Argue: do D4 first (which touches syncAllToStore inside History), THEN split once the hot-path code has churned, so the split does not immediately conflict. Or argue defer-split-until-forced. Identify the exact conditions under which splitting now is NOT premature.' },
]

const proposals = await pipeline(
  LENSES,
  (lens) => agent(
    `${CONTEXT}\n\n=== YOUR LENS: ${lens.key} ===\n${lens.angle}\n\nProduce your proposal for THE NEXT STEP on History.swift. Read the files. Be specific and concrete — names, order, PR sequence, what you exclude. The hollow-ness test is absolute: if your proposal merely relocates coupling or changes nothing at runtime and doesn't clear the lint wall or unblock an existing test, say so honestly in wouldHaveBeenHollowAsB1=true.`,
    { label: `propose:${lens.key}`, phase: 'Propose', schema: PROPOSAL_SCHEMA }
  ),
  (proposal, lens) => agent(
    `${CONTEXT}\n\n=== ADVERSARIAL ATTACK ===\nYou are a ruthless skeptic. A colleague proposed this next-step for splitting History.swift:\n\n${JSON.stringify(proposal, null, 2)}\n\nAttack it on ONE criterion above all: IS IT HOLLOW? Apply the B1 test literally — B1 was reverted because its adapter still called AppState.shared in every method (coupling relocated, runtime unchanged, testability not unblocked). Does THIS proposal do the same thing? Check: does it relocate coupling? does it change runtime? does it unblock a test that EXISTS TODAY (not a hypothetical future one)? does it clear the hard file_length wall? Then find the cost it underweighted (observation binding, test churn, merge conflict with the D4/C2/C3 work that edits the same file, PR count, premature port expansion for a test that doesn't exist yet). Finally: what is the MINIMAL change that would convert it from hollow to concrete-value, and after all that — does it SURVIVE as worth doing now? Read the files to verify claims.`,
    { label: `attack:${lens.key}`, phase: 'Attack', schema: SKEPTIC_SCHEMA }
  ).then((skeptic) => ({ lens: lens.key, proposal, skeptic }))
)

const survived = proposals.filter(Boolean).filter(p => p.skeptic && p.skeptic.survives)
const hollow = proposals.filter(Boolean).filter(p => p.skeptic && !p.skeptic.survives)

return {
  total: proposals.filter(Boolean).length,
  survivedCount: survived.length,
  hollowCount: hollow.length,
  proposals: proposals.filter(Boolean),
  survived: survived.map(p => ({ lens: p.lens, step: p.proposal.recommendedNextStep, value: p.proposal.concreteValueDelivered, order: p.proposal.order, skepticMadeItConcrete: p.skeptic.whatWouldMakeItConcrete })),
  hollow: hollow.map(p => ({ lens: p.lens, step: p.proposal.recommendedNextStep, whyHollow: p.skeptic.hollowReasoning, missedCost: p.skeptic.missedCost })),
}
