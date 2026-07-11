# E3 Clipboard polling Timer plan

**Goal:** Finish DS-024 without changing the configured clipboard polling cadence: use a coalescible Timer and keep it active in common run-loop modes. DS-028 is no longer part of this step because E4 already deleted the unreachable paste-stack/multi-select subtree in `9849d00`.

## Design

`Clipboard.start()` will derive a small value configuration from the user default. The configuration clamps the interval to the existing 100 ms floor, sets tolerance to 10% of that effective interval, and selects `.common`. `start()` will construct an unscheduled Timer, apply the tolerance, and explicitly register it on `RunLoop.main` with that mode.

The value configuration is intentionally the only new seam. It makes the energy/responsiveness policy testable without introducing a scheduler protocol for one call site, while the production method remains the sole Timer owner.

## Invariants

- The effective interval remains `max(0.1, Defaults[.clipboardCheckInterval])`.
- Tolerance is 10% of the effective interval, including after the floor is applied.
- The Timer is registered in `.common`, so menu/event tracking does not suspend clipboard polling.
- `restart()` continues to invalidate the previous Timer before starting the replacement.
- No paste-stack or multi-select work is revived; E4 already closed DS-028.

## TDD and verification

1. Add focused configuration tests for the default interval and the clamped interval; capture the missing-configuration compile red.
2. Implement the value configuration and replace `scheduledTimer` with explicit Timer construction/tolerance/common-mode registration.
3. Run static checks, strict lint, unit tests, and the full macOS matrix. Known runner-contention UI/performance flakes are classified once and not repeatedly rerun.
4. Update DS-024, the master roadmap, and this plan with the CI evidence.

## Files and commits

- Modify: `Maccy/Clipboard.swift`
- Modify: `MaccyTests/ClipboardTests.swift`
- Modify: `docs/audit/2026-07-10-master-roadmap.md`
- Modify: `docs/audit/2026-07-09-design-structure-audit/17-findings-catalog.md`
- Modify: `docs/audit/INDEX.md`

- `test(e3): define clipboard timer policy`
- `fix(e3): keep polling active in common modes`
- `docs(e3): record clipboard timer evidence`

## Evidence

- Red: workflow `29145191058` on `5b994fe` compiled the app, then failed every shard that reached `MaccyTests/ClipboardTests.swift` with the expected two `Type 'Clipboard' has no member 'timerConfiguration'` errors. The run was cancelled immediately after the compile-red was captured.
- Green: `32320cf` adds the configuration and explicitly scheduled Timer. Workflow `29145295608` passed strict lint/diagnostics, the complete unit suite (including both new Timer policy tests), both UI shards, and all three performance shards.
- Static proof: `Timer.scheduledTimer` no longer appears in `Clipboard`; `start()` sets `timer.tolerance` before registering the Timer through `RunLoop.main.add(..., forMode: .common)` via the tested configuration.

E3 is complete. DS-024 is closed; DS-028 remains closed independently by the earlier E4 deletion (`9849d00`).
