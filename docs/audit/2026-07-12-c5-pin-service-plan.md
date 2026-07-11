# C5 PinService plan and evidence

**Goal:** Close DS-015 by removing persistence queries and shortcut-allocation policy from the `HistoryItem` SwiftData entity without changing pin behavior.

## Design

`PinService` is a concrete `@MainActor` module over a caller-provided `ModelContext`. It owns the supported-key policy, fetches assigned pins, derives the remaining set, and selects a random free key. The module uses the existing in-memory SwiftData test store directly; no protocol was introduced because production and tests do not require distinct adapters.

`PinsSettingsPane` constructs the module from its existing `@Environment(\.modelContext)`. `HistoryItemDecorator` accepts the same module through its initializer and uses it when toggling an unpinned item. Existing callers retain a default production composition, while tests can supply a context explicitly. `HistoryItem` now contains no pin query or `Storage.shared` access.

## Invariants

- Reserved shortcuts and the supported pin set are unchanged.
- Assigned non-`nil` pins are excluded; empty-string pins retain their prior no-op subtraction behavior.
- Fetch failures are still logged and degrade to the full supported set, matching the previous behavior.
- Unpinning still sets `item.pin` to `nil`; pinning still chooses a random free key.
- Settings continue to refresh available keys on appearance and after a pin change.
- The new source file is added only through the pinned XcodeGen workflow; no project node is hand-authored.

## TDD and verification

- Red: `783ca3c` + `5660c9a` added context-backed availability tests and fixture cleanup. Workflow `29154162661` failed at `MaccyTests/HistoryPinPersistenceTests.swift` with the expected `Cannot find 'PinService' in scope` compile errors.
- Implementation: `76a2a53` added `PinService`, injected it into the decorator, routed the settings pane through its environment context, and removed the static query/policy from `HistoryItem`. `9c81a48` preserved the entity's unrelated `Logging` import after the first generated clean build exposed that dependency.
- Generated project: workflow `29154445186` generated the exact four-line `PinService.swift` project addition, passed repeatability/test-plan/clean-build/bundle gates, and failed only the expected pre-commit parity/drift checks. Artifact output was committed unchanged in `b49b462` (pbxproj SHA-256 `57783195346c921b47f4ef4cee94b95f1daba2504825d23c8417277ae763b703`).
- Green: workflow `29154584664` passed production generation and zero drift, the generated-project unit shard (including both new tests), both UI shards, both performance shards, and the generated Release package job.
- Static boundary proof: `HistoryItem.swift` has no `availablePins`, `randomAvailablePin`, `supportedPins`, `FetchDescriptor`, or `Storage.shared` references. Both production call paths enter through `PinService`.

C5 is complete and DS-015 is closed.
