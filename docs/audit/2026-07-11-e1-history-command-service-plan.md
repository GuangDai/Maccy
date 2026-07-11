# E1 HistoryCommandService plan

**Goal:** Give App Intents one main-actor application port, one 1-based index convention, and stable full-history positional semantics independent of the popup's transient search filter.

**Findings:** DS-018, `NEW-singletons-intents-misc-2`, and `NEW-singletons-intents-misc-3`. `Get`, `Select`, `Delete`, and `Clear` directly reach `AppState.shared`; three intents duplicate bounds logic; indexed intents resolve against filtered `History.items` even though their contract says “position in history.”

**Design:** Add `@MainActor HistoryCommandService` plus an app implementation and a main-actor registry in the existing shared Intent support source (avoiding one more hand-edited legacy pbxproj entry before XcodeGen cutover). The implementation receives `History` and `NavigationManager` at composition time, resolves one-based positions through a single private method against `history.all`, and owns get/select/delete/clear commands. `AppDelegate` wires it once; Intents depend only on the protocol registry.

## Invariants

- Position `1` means `history.all[0]`; zero, negative, and out-of-range positions throw `AppIntentError.notFound`.
- Active search/filter state never changes indexed Intent meaning.
- Selected-item behavior continues to use `NavigationManager.selection`.
- Existing confirmation behavior for Clear and entity projection/file protection for Get remain unchanged.
- Intents contain no `AppState.shared` references after migration; composition owns that dependency.
- No new source file is added to the still-authoritative legacy project. The type can move to its own file after declarative-project cutover.

## TDD and verification

1. Add service characterization tests to the existing `HistoryTests` target: one-based full-history resolution while `items` is filtered, invalid bounds, and selected-item resolution. Capture the missing-service compile red.
2. Implement the service/registry and wire it in `AppDelegate`.
3. Migrate Get/Select/Delete/Clear without changing their user-facing metadata or output behavior.
4. Prove no direct AppState reference remains under `Maccy/Intents`, then run strict lint and the full macOS matrix.
5. Record evidence and close all three E1 findings.

## Files and commits

- Modify: `Maccy/Intents/AppIntentError.swift`
- Modify: `Maccy/Intents/Get.swift`
- Modify: `Maccy/Intents/Select.swift`
- Modify: `Maccy/Intents/Delete.swift`
- Modify: `Maccy/Intents/Clear.swift`
- Modify: `Maccy/AppDelegate.swift`
- Modify: `MaccyTests/HistoryTests.swift`
- Later evidence: `docs/audit/2026-07-10-master-roadmap.md`, verification docs, `docs/audit/INDEX.md`

- `test(e1): define stable history command positions`
- `refactor(e1): route intents through HistoryCommandService`
- `docs(e1): record intent port evidence`

## Evidence

- Red: workflow `29144262259` reached the intended compile boundary with exactly the three missing `AppHistoryCommandService` references from the new characterization tests.
- Green implementation: `967c00b` added the tests and `1f9f71c` added the port, registry, composition wiring, and Intent migrations. Workflow `29144397392` compiled and passed all three new tests; its self-scan then correctly rejected three unused-result warnings in the expected-throw assertions.
- Warning fix: `cd368ea` explicitly consumes the throwing expressions. Workflow `29144528919` passed strict lint/diagnostics, the complete unit shard, `perf-text`, `perf-image`, and `ui-2`. Its first `ui-1` attempt failed only the repository-known `testClear` 3-second asynchronous wait under runner contention; the succeeding test and all other 21 tests in that shard passed. Per the standing no-flake-rerun policy, the isolated rerun was cancelled rather than used as correctness evidence.
- Static boundary proof: `rg -n 'AppState\.shared|positionOffset|number -' Maccy/Intents` returns no matches. All four Intents now enter through `HistoryCommandService`, and the one-based resolver exists only in `AppHistoryCommandService`.

E1 is complete. The temporary placement in `AppIntentError.swift` remains intentional until the generated Xcode project becomes authoritative; it avoids another manual legacy `pbxproj` source entry.
