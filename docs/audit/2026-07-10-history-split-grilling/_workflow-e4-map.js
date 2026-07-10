export const meta = {
  name: 'e4-paststack-deletion-map',
  description: 'Map the precise, behavior-neutral deletion of the dead paste-stack/multi-select subtree (E4) — per-file edits + pbxproj surgery + verification',
  phases: [
    { title: 'Map', detail: 'parallel: pbxproj / NavigationManager / other-live-files / behavior-neutrality' },
    { title: 'Synthesize', detail: 'one verified, ordered deletion checklist' },
  ],
}

const CONTEXT = `
PROJECT: Maccy (macOS clipboard manager, Swift 6.0 strict concurrency, AppKit+SwiftUI+SwiftData). No local toolchain; CI on GitHub Actions is the gate. Manual (non-synced) pbxproj.

TASK (E4 / NEW-singletons-intents-misc-1 / DS-028): delete the dead paste-stack / multi-select subtree. It is gated by \`AppState.multiSelectionEnabled\` which is an immutable \`nonisolated let = false\` (AppState.swift:15, no other assignments) — so ALL multi-select/paste-stack BEHAVIOR is dead (never executes). But the CODE is referenced by live files, so deleting it means editing those live files to strip the dead branches.

CRITICAL — what is LIVE and MUST be preserved:
- \`Selection<Item>\` (Selection.swift) is the LIVE single-selection container (NavigationManager.selection, selectionIndex mirroring). It has multi-item API (forEach/count/add) used for single selection too (count 1). Do NOT delete Selection.swift; only remove genuinely-unused multi-item entry points if any.
- NavigationManager's single-selection model: \`selection\`, \`leadHistoryItem\`, \`scrollTarget\`, \`select(item:)\`, \`highlightFirst()\`, keyboard-nav (\`isKeyboardNavigating\`, hover-while-keyboard), preview triggering. These are LIVE and must keep working identically.
- Single-item selection, scroll-to-item, preview-on-lead, pin/shortcuts — all live.

What is DEAD (multiSelectionEnabled=false makes these never-execute):
- \`AppState.multiSelectionEnabled\` itself.
- \`PasteStack.swift\`, \`History+PasteStack.swift\` (startPasteStack/handlePasteStack/interruptPasteStack — all guard on multiSelectionEnabled), \`PasteStackView.swift\`, \`PasteStackPreviewView.swift\`, \`PasteStackItemView.swift\`.
- \`History.pasteStack\` property + its uses.
- NavigationManager: \`isManualMultiSelect\`, \`isMultiSelectInProgress\` (always false), \`pasteStackSelected\`, \`addToSelection\`, \`extendSelection\`, the pasteStack branch in \`leadSelection\`, multi-select branches in select/scroll logic.
- HistoryItemView: the ⌘-click \`addToSelection\` (line ~60) + \`selectionIndex\`-based multi-select display.
- KeyChord: the \`multiSelectionEnabled\` param + the 4 \`.extendTo*\` cases (always become \`.moveTo*\`).
- KeyHandlingView: the 4 \`guard multiSelectionEnabled\` blocks + \`pasteStackSelected\`/\`deleteSelection\` paths.
- AppState: \`pasteStack\`/\`pasteStackSelected\` plumbing + \`deleteSelection()\`.
- SlideoutController: the pasteStack pane branches.
- HistoryListView: the pasteStack rendering branches.
- HoverSelectionModifier: the \`!isMultiSelectInProgress\` term.
- History.swift: \`pasteStack\` var + the \`!AppState.shared.navigator.isMultiSelectInProgress\` terms in insertIncrementally (~379) and reconcileWithStore (~445) — these simplify (the term is always true).
- Clipboard, ContentView, ToolbarView, SlideoutContentView: pasteStack/multi-select branches.

PBXPROJ: each dead .swift file has 4 pbxproj lines (PBXBuildFile, PBXFileReference, a group-children entry, a Sources-phase entry). Removing a file = removing its 4 lines. The 5 files' UUIDs (from grep): PasteStack.swift (2F0EC780/2F0EC781), PasteStackView.swift (2F0EC784/2F0EC785), PasteStackItemView.swift (2F0EC786/2F0EC787), PasteStackPreviewView.swift (2F162E7F/2F162E80), History+PasteStack.swift (DA0806C1/DA0806C2).

READ THESE TO GROUND THE MAP: Maccy/Observables/NavigationManager.swift, Maccy/Observables/AppState.swift, Maccy/Observables/History.swift (pasteStack var + the isMultiSelectInProgress terms), Maccy/Observables/History+PasteStack.swift, Maccy/Observables/SlideoutController.swift, Maccy/Views/{HistoryItemView,KeyHandlingView,HistoryListView,HoverSelectionModifier,ContentView,ToolbarView,SlideoutContentView,PasteStackView,PasteStackPreviewView,PasteStackItemView}.swift, Maccy/KeyChord.swift, Maccy/PasteStack.swift, Maccy/Selection.swift, Maccy/Clipboard.swift, Maccy.xcodeproj/project.pbxproj.
`

const MAP_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['area', 'findings', 'edits', 'risks'],
  properties: {
    area: { type: 'string' },
    findings: { type: 'string', description: 'What you found in the files (dead vs live, exact symbols/lines).' },
    edits: { type: 'string', description: 'The precise edits for your area (file: what to delete/change). For pbxproj: the exact lines/UUIDs. Be concrete enough to execute from.' },
    risks: { type: 'string', description: 'Any behavior-change risk or subtlety in your area (a live path that depends on the removed code).' },
  },
}

const VERIFY_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['singleSelectionPreserved', 'allStrippedPathsDead', 'liveDependsOnRemoved', 'selectionTypeOutcome', 'verdict'],
  properties: {
    singleSelectionPreserved: { type: 'boolean', description: 'true if single-selection/scroll/preview/lead all behave identically after the deletion' },
    allStrippedPathsDead: { type: 'boolean', description: 'true if EVERY stripped branch was gated by multiSelectionEnabled=false or isMultiSelectInProgress=false (never executed)' },
    liveDependsOnRemoved: { type: 'string', description: 'any LIVE code that depends on a removed symbol (would break). "none" if clear.' },
    selectionTypeOutcome: { type: 'string', description: 'Should Selection<> stay (live) — yes. Are its multi-item entry points (addToSelection/extendSelection) used by live single-selection? If not used, can they go? Answer precisely.' },
    verdict: { type: 'string', description: 'safe-to-delete-as-mapped / needs-adjustment' },
  },
}

const AREAS = [
  { key: 'pbxproj', task: 'Map the EXACT pbxproj lines to remove for the 5 dead files (PasteStack.swift, PasteStackView.swift, PasteStackItemView.swift, PasteStackPreviewView.swift, History+PasteStack.swift). For each: the PBXBuildFile line, the PBXFileReference line, the group-children entry, the Sources-phase entry. List line numbers/content. Confirm no OTHER pbxproj references. Verify the group they live in stays valid (not left empty/malformed).' },
  { key: 'navigationmanager', task: 'Map NavigationManager.swift precisely: which symbols/branches are DEAD (isManualMultiSelect, isMultiSelectInProgress, pasteStackSelected, addToSelection, extendSelection, the pasteStack branch in leadSelection, multi-select branches in select/scroll/keyboard-nav) vs LIVE (selection, leadHistoryItem, scrollTarget, select, highlightFirst, isKeyboardNavigating, hover-while-keyboard, preview triggering). Give exact line-by-line edits that strip the dead parts while preserving single-selection byte-for-byte. This is the highest-risk file — be precise.' },
  { key: 'live-files', task: 'Map the OTHER live files: HistoryItemView (⌘-click addToSelection + selectionIndex multi-display), KeyChord (multiSelectionEnabled param + 4 extendTo* cases → always moveTo*), KeyHandlingView (4 guard multiSelectionEnabled + pasteStackSelected/deleteSelection), AppState (pasteStack/pasteStackSelected/deleteSelection), SlideoutController (pasteStack pane branches), HistoryListView (pasteStack rendering), HoverSelectionModifier (!isMultiSelectInProgress term), History.swift (pasteStack var + the two !isMultiSelectInProgress terms — simplify), Clipboard/ContentView/ToolbarView/SlideoutContentView (pasteStack/multi-select branches). Per file: exact dead symbols/branches to strip + the simplification. Note History.swift pasteStack var removal + its ripple (History+PasteStack.swift uses it).' },
  { key: 'verify', task: 'ADVERSARIALLY VERIFY behavior-neutrality. Read every live file that references a removed symbol. Confirm: (1) every stripped branch was gated by multiSelectionEnabled=false or isMultiSelectInProgress=false (never ran); (2) single-selection/scroll/preview/lead behave identically after; (3) no LIVE code depends on a removed symbol (would break compile or behavior); (4) Selection<> stays (live) — are its multi-item entry points used by live single-selection, or can they go? Be the skeptic who finds the one live path that breaks.' },
]

const mapped = await parallel(AREAS.map(a => () =>
  agent(`${CONTEXT}\n\n=== YOUR AREA: ${a.key} ===\n${a.task}\n\nRead the files. Produce a precise, executable map for your area. If you find something LIVE that depends on dead code (would break), flag it in risks — do not hand-wave.`,
    { label: `map:${a.key}`, phase: 'Map', schema: a.key === 'verify' ? VERIFY_SCHEMA : MAP_SCHEMA })
))

const ok = mapped.filter(Boolean)
return {
  total: ok.length,
  verify: ok.find(r => r && r.area === 'verify') || ok.find(r => r && r.verdict),
  maps: ok.filter(r => r && r.area !== 'verify').map(r => ({ area: r.area, edits: r.edits, risks: r.risks })),
}
