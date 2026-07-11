# E2 package organization plan

**Goal:** Close DS-026 and DS-034 with behavior-neutral package organization: colocate the search module, move DEBUG-only notification plumbing out of `AppDelegate`, and move infrastructure wiring into a concrete composition root.

## Design

Three mechanical slices keep review and failure attribution local:

1. Move `Search.swift`, `SearchActor.swift`, `SearchDTOs.swift`, and `SearchVisibility.swift` into `Maccy/Search/` without source edits.
2. Add a DEBUG-only `DebugHooks` module that owns UI-test/performance distributed-notification names, observer tokens, Sparkle test suppression, install, dump, and removal. `AppDelegate` forwards its three lifecycle points to that module.
3. Add `CompositionRoot`, initialized lazily with the existing application objects. It installs the AppDelegate bridge and Intent command module, constructs the background ingestor, starts/restarts clipboard polling, and attaches memory governance. Move `AppDelegate` and `MaccyApp` beside it under `Application/`; the delegate retains status-item/window/defaults UI responsibilities and calls the small lifecycle interface.

No protocol is added: production and tests do not have two justified adapters. Concrete dependencies are accepted by `CompositionRoot` so wiring knowledge is localized without building a repository/service-locator layer.

## Invariants

- Launch ordering remains: DEBUG updater suppression; app/Intent/ingest wiring and clipboard start; status-item observers; migrations/hotkeys/panel; memory governor; DEBUG hooks.
- The same singleton instances and shared image processor remain the production defaults.
- Clipboard interval updates still restart the same clipboard instance.
- All distributed-notification names, command-line gates, main-actor hops, perf fallback dump, and observer cleanup remain byte-for-byte equivalent in behavior.
- Search declarations and access levels are unchanged; only filesystem/project grouping changes.
- Release contains no `DebugHooks` implementation.
- The pinned XcodeGen workflow produces every moved/new project reference; the pbxproj is never hand-edited.

## Execution and verification

1. Commit the four search moves.
2. Extract `DebugHooks` and reduce `AppDelegate` DEBUG branches.
3. Extract `CompositionRoot` and reduce launch wiring.
4. Run static path/responsibility checks.
5. Use `Regenerate and Validate Xcode Project` to clean-build and capture the generated project artifact; commit the artifact unchanged.
6. Re-run generated-project repeatability/zero-drift, unit/UI/performance shards, and Release packaging. Then run the normal master CI gate.
7. Update DS-026/DS-032/DS-034, the master roadmap, and this record with commit/run evidence.

Known runner-contention timeouts and microbenchmark RSD failures are recorded once and not rerun.

## Evidence

- Search package: `2a06a58` moved all four `Search*` sources with 100% rename similarity and zero source-line changes.
- DEBUG package: `72fa8f2` moved notification names, observer ownership, Sparkle test suppression, install/remove, and fallback perf dump into a whole-file `#if DEBUG` `DebugHooks` module.
- Application package: `9e54d77` added the lazily initialized `CompositionRoot`, moved `AppDelegate`/`MaccyApp` under `Application/`, and localized Intent/ingest/clipboard/memory wiring. Lazy composition plus call-time `MemoryGovernor.shared` evaluation preserves the original singleton initialization order.
- Generated project: workflow `29167009077` passed repeatability, generated test-plan, clean build, and bundle checks, then failed only the expected pre-commit parity/drift gates for the two new sources and package paths. Its exact project artifact was committed in `19b7431` (pbxproj SHA-256 `60bdb2ab84398908e06265a51852ebe30e2c8bc5470dcf92a2592b0951e01df7`).
- Green: workflow `29167115880` passed production generation and zero drift, the generated Release package, unit, both UI shards, and both performance shards. No contention failure required classification.
- Static result: root-level Swift files fell from the verified audit baseline of 29 to 22; `Application/` contains four cohesive sources; `Search/` contains exactly the four search sources; `AppDelegate` is 209 lines and contains no notification bridge, background-ingestor construction, Intent registry wiring, or memory-governor wiring.

E2 is complete. DS-026, DS-032, and DS-034 are closed at the roadmap-defined package/wiring seam; progressive replacement of remaining singleton defaults remains E5.
