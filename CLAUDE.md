# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Maccy is a lightweight macOS clipboard manager (AppKit + SwiftUI + SwiftData). It targets macOS Sonoma 14+ (`MACOSX_DEPLOYMENT_TARGET = 14.0`) and builds with **Swift 6.0** in **complete** strict-concurrency mode (`SWIFT_STRICT_CONCURRENCY = complete`) with **zero** `@unchecked Sendable` / `nonisolated(unsafe)`. A C++/ObjC++ interop layer in `Maccy/Processor/` (UTF-8 prefix validation, **xxh3** dedup fingerprinting via vendored xxHash) is bridged through ObjC++; the legacy FNV-1a hash is retained but not called.

The performance/concurrency refactor (off-main ingest/image/search, two-domain isolation, History facade split, xxh3 dedup) has **landed**. For the current architecture, data flow, and load-bearing decisions see `docs/ARCHITECTURE.md` and `docs/DECISIONS.md` (the two lean, HEAD-accurate docs). Don't look for the old `docs/audit/` roadmap/audit tree — it was deleted as stale.

## Build, lint, test — there is NO local environment

This machine has no Xcode / macOS toolchain. **Do not build, run tests, or run `swiftlint` locally — none of it will work.** All building, linting, and testing happens on the GitHub Actions runner (macOS 26 / arm64). You drive it through `gh`, then poll for the result.

The workflow is `.github/workflows/macos26-arm-ci.yml` (workflow name: **"macOS 26 ARM CI"**). It triggers automatically on push/PR to `master`, and supports `workflow_dispatch` for manual runs on any branch:

Most of time, you only need automatically trigger. Don't trigger multiple times at the same time.

```sh
# Trigger a run on the current branch
gh workflow run "macOS 26 ARM CI" --ref "$(git rev-parse --abbrev-ref HEAD)"

# List recent runs (note the run id / database id of the one you care about)
gh run list --workflow "macOS 26 ARM CI" --limit 5

# Check a run's status non-interactively (use this to poll)
gh run view <run-id>
gh run view --workflow "macOS 26 ARM CI"     # most recent run
```

**Polling rule (important):** a CI run takes **~11 minutes** end-to-end. When a run is still in progress, **re-check no more often than every 30 seconds** — never high-frequency poll, and don't use `gh run watch` for tight polling. Get the status once; if it isn't finished, wait at least 30 seconds before the next check.

**Investigating a failed run — do this, in this order (learned the hard way):**

1. **Status first, not the log.** A run is a *matrix* of jobs: `Lint + diagnostics`, then `project-generation`, then shards (`unit`, `ui-1`, `ui-2`, `perf-text`, `perf-image`). "Run failed" tells you nothing — find *which* job(s) failed:
   ```sh
   gh run view <run-id> --json jobs -q '.jobs[] | "\(.name): \(.conclusion)"'
   ```
   Two very different signals: `Lint + diagnostics` failed (→ all shards `skipped`; it's a SwiftLint/build error in *your* change, always real) vs. one shard failed while the rest passed (often a contention flake). Note: **perf shards are blocking** (a perf timeout/hang fails the run like a unit/UI failure).
2. **Read the failed job's log from the END.** `gh run view --job=<job-id> --log` dumps the whole build; the **head is noise** (checkout, `brew install swiftlint`, `Compiling …`, `RegisterExecutionPolicyException`, framework bottles). The actual failure — the `error:`/`XCTAssert … failed` line, `** TEST FAILED **`, the `Failing tests:` block, or a crash signature — is in the **last few dozen lines**. Tail it (`| tail -n 60`) or grep the tail. **Don't grep the whole log blind** — `RegisterExecutionPolicyException` and `relative standard deviation` lines will drown the signal (and note `grep -E ".*"` patterns containing `**` are invalid regex).
3. **Distinguish flake from real failure before rerunning.** Known runner-contention flakes (logic-verified — don't loop reruns): 3 s async-wait timeouts on `testCopy*`/`testClear`/`testPin` on contended UI shards; perf `measure{}` RSD>10 % on sub-millisecond micro-benchmarks. A *real* failure leaves a concrete `error:`/assertion/crash in the tail (e.g. SwiftData `fatal logic error in DefaultStore … Persistent Identifier remapped to a temporary identifier during save` — that one aborts the whole test class, so every test in the class shows as failed, including ones that never ran).

**The runner is the gate of truth.** A green run is the only acceptable evidence a change passed: the workflow's self-scan greps each blocking shard log (`swiftlint.log`, shard logs) for `warning:` / `error:` / `TEST FAILED` / `Fatal error` / `[Ff]ailed`, piped through a `grep -vE` allowlist of benign runner noise + deliberately-triggered error-path test logs. It's a heuristic to surface real errors — don't reword code/log messages to dodge it; add expected lines to the allowlist instead.

What the runner executes (reference only — do not run locally): XcodeGen drift gate (regenerate twice, zero diff) → SwiftLint (`swiftlint lint --quiet --strict --no-cache`) → `xcodebuild` clean build → unit tests (`-only-testing:MaccyTests`) → UI tests (`-only-testing:MaccyUITests`), all with `-project Maccy.xcodeproj -scheme Maccy -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO`. XcodeGen owns the project (`project.yml` is the spec; the committed `Maccy.xcodeproj` is generated output — never hand-edit pbxproj). To run a narrower test on the runner, push a temporary commit that passes `-only-testing:MaccyTests/<Class>[/<method>]` rather than trying to run it locally.

`enable-testing` (injected by `Maccy.xctestplan`) forces `Storage` to an in-memory SwiftData store and gates several paths (`AppDelegate`, `Notifier`, `HistoryItem`) — so test-run behavior differs from the shipped app.

Release packaging: `scripts/package-app.sh` (Release build → zips `Maccy.app` → emits `.sha256`); driven by `.github/workflows/release.yml` on version tags, which also runs the xcodeproj drift gate + `verify-release-optimizations.sh` (enforces C/C++ O2+, Swift `-O` whole-module).

## Architecture

### Two-domain isolation model
The data pipeline is split across two domains that communicate **only via Sendable value types (DTOs)** — a `@Model` (`HistoryItem`/`HistoryItemContent`) never crosses an actor boundary:

- **Main** — SwiftUI views + thin `@Observable` view models (`AppState`, `History` facade, `HistoryItemDecorator`, `Popup`, `SlideoutController`, `NavigationManager`, …) + `mainContext` reads. All `@MainActor`.
- **Background actors** — `BackgroundClipboardIngestor` (`@ModelActor`; bare `ClipboardIngestor` is the Sendable protocol) reads the pasteboard via a FIFO `IngestMailbox`, dedups via a per-entry `SignatureIndex`, writes one transaction to its **own** `ModelContext` (built via the `@ModelActor` macro — there is no `Storage.newBackgroundContext()`), then emits a `StoreEvent`; `ImageProcessor`/`ThumbnailCache` downsample/decode; `SearchActor` runs the 4-mode text match. `History.consume`/`HistoryStoreProjector` apply the event on main (incremental via `model(for:)` + binary insert, full reconcile fallback). An outward `HistoryUIEffect` value port (`closePopup`/`resizePopup`/`select`/`highlightFirst`/`scrollTo`) carries History→UI requests; it is emitted on real content/geometry changes, **not** on search.

`Storage` (`Maccy/Storage.swift`) is `@MainActor`; `Storage.shared.context` is `container.mainContext` (Main domain only). Detail in `docs/ARCHITECTURE.md`; decisions in `docs/DECISIONS.md`.

### Test infrastructure
Unit/integration tests in `MaccyTests/`, UI tests in `MaccyUITests/`. Test doubles and fixtures live in `MaccyTests/Support/` (`PasteboardSimulator`, `HistoryBuilder`, `FakeClock`, `IngestorSpy`, `FixtureLoader`, `MainThreadProbe`, `HistoryTestDriver`). Test fixtures (e.g. `heavy_text.txt`, `guy.jpeg`) live in `MaccyTests/Fixtures/` and are loaded by `FixtureLoader` via `#filePath`-relative paths. Perf tests live in `MaccyTests` (`TextSearchPerformanceTests`, `ImageDecodePerformanceTests`) and run in the blocking `perf-text`/`perf-image` shards; they emit `PERF|...` lines at runtime (no checked-in baseline) with only a `<16 ms` main-thread budget assertion.

### Other key pieces
- Dedup fingerprints + UTF-8 validation: C++/ObjC++ in `Maccy/Processor/` — **xxh3** is the live hash; the persistent `HistoryItemContent.fingerprint` column (lightweight SwiftData migration) caches it, and is lazily backfilled for legacy rows inside the ingest commit.
- Translations: per-language `*.lproj/` directories, managed via BartyCrouch (`.bartycrouch.toml`) and Weblate — do not hand-edit locale strings (only the English source `*.strings`).
- User-facing defaults: `defaults write org.p0deje.Maccy ...` keys (`ignoreEvents`, `clipboardCheckInterval`, `showFooter`, …) — see README "Advanced". Declared once in `Maccy/Extensions/Defaults.Keys+Names.swift`.
