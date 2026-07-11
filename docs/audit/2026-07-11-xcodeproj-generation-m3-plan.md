# XcodeGen M3 production cutover plan

> **For agentic workers:** execute one task/commit at a time. Never hand-edit generated `project.pbxproj` content.

**Goal:** Make `project.yml` + checked xcconfigs the editable project truth, replace the legacy `Maccy.xcodeproj` with deterministic XcodeGen output, and make normal CI/release reject stale generated output before building or publishing.

**Architecture:** Change the declarative project name to `Maccy`, centralize in-place regeneration (including package-lock preservation and canonical test-plan target-ID refresh), and repurpose the registered manual generated-project workflow to emit the first cutover artifact. The initial run is expected to fail only its committed-output drift gate while still uploading the generated project/plan. Mechanically replace the tracked legacy output with that artifact, then require a zero-diff manual run, full generated matrix, Release dry run, normal CI generation gate, and release generation gate.

**Prerequisite evidence:** M2 run `29146217892` proved the side-by-side generated graph/settings, target-ID test plan, all five unit/UI/performance shards, and Release package path.

## Invariants

- Humans edit `project.yml`/`Config/*.xcconfig`; `Maccy.xcodeproj` is checked generated output.
- No manual pbxproj line edits are allowed after cutover.
- `Maccy.xctestplan` remains checked input, but its three deterministic target IDs are refreshed from the generated pbxproj by a script; `enable-testing` must remain.
- `Package.resolved` remains canonical inside `Maccy.xcodeproj` and survives every regeneration byte-for-byte.
- Two uncached in-place regenerations are byte-identical.
- Normal CI and release run generation + test-plan refresh and fail on any tracked diff before consuming the committed project.
- The first whole-file rewrite is accepted only from the runner artifact whose semantic M2 contract already passed.
- Existing unit/UI/performance selection, fault-injection allowlists, Swift 6 complete mode, C++/ObjC++ settings, packages, resources, and 31-language set do not change.

---

## Task 1: Generalize the production regeneration entry point

**Files:**

- Modify: `project.yml`
- Delete: `Maccy-Generated.xctestplan`
- Modify: `scripts/generate-xcodeproj.sh`
- Create: `scripts/update-test-plan-target-ids.sh`
- Create: `scripts/regenerate-xcodeproj.sh`
- Modify: `scripts/verify-generated-test-plan.sh`

1. Rename the generated project to `Maccy`, remove the side-by-side plan reference, and reference canonical `Maccy.xctestplan` from the scheme.
2. Parameterize the low-level generator's expected project name.
3. Add a target-ID updater that derives the app/unit/UI `PBXNativeTarget` IDs from a fresh pbxproj and changes only the canonical plan's `containerPath`/`identifier` fields.
4. Add one production regeneration command that preserves/restores canonical `Package.resolved`, invokes pinned generation, refreshes plan IDs, and verifies project/plan/scheme agreement.
5. Make the verifier generic over project/plan basenames.
6. Locally run JSON/JQ shape checks and `bash -n`; the macOS runner is the plutil/Xcode gate.
7. Commit as `build(xcodegen-m3): define production regeneration`.

## Task 2: Convert the registered manual workflow into the cutover producer

**Files:**

- Modify: `.github/workflows/xcodeproj-generated.yml`

1. Save the pre-generation project for one-time semantic comparison evidence.
2. Run production regeneration twice, snapshot the first project+plan, and require byte-for-byte repeatability.
3. Verify graph/settings/bundle/package/test-plan contracts and upload the generated `Maccy.xcodeproj` + `Maccy.xctestplan` even when committed-output drift fails.
4. Point the existing five semantic shards and Release dry-run at `Maccy.xcodeproj` from that artifact.
5. The initial run may fail only the drift outcome; all preceding generation/parity/build gates must pass.
6. Commit as `ci(xcodegen-m3): produce production project artifact`.

## Task 3: Land the first generated output mechanically

1. Wait for the current default-branch CI; do not overlap workflows.
2. Dispatch the manual workflow once.
3. Confirm job status/log tail: expected first-run failure is the committed-output diff only.
4. Download its evidence artifact and mechanically replace only `Maccy.xcodeproj` and `Maccy.xctestplan`; do not hand-edit the output.
5. Review semantic summaries, package lock, scheme plan reference, and changed-file scope.
6. Commit as `build(xcodegen-m3): replace legacy project output`.

## Task 4: Add normal CI and release drift gates

**Files:**

- Modify: `.github/workflows/macos26-arm-ci.yml`
- Modify: `.github/workflows/release.yml`

1. Add a parallel `Generated Xcode project` job to normal CI: regenerate twice, compare snapshots, and require `git diff --exit-code` on project, plan, and package lock.
2. Make test shards depend on both lint and generation jobs; they continue using the committed `Maccy.xcodeproj` proven fresh by the gate.
3. Add the same production regeneration + zero-diff check immediately after release checkout and before packaging.
4. Keep both paths read-only; they fail stale branches/tags instead of silently repairing them.
5. Commit as `ci(xcodegen-m3): reject stale project output`.

## Task 5: Cutover acceptance

1. Dispatch the manual workflow again. Require zero drift, all generation/parity/build/bundle/test-plan gates, all five shards, and Release dry run green. Known runner flakes are classified once and not rerun.
2. Merge to `master`; require normal CI's new generation job plus all existing shards green.
3. If safe to validate without publishing, dispatch release with `publish=false` and require its generation gate/package artifact green.
4. Update project ownership docs, the M2/M3 research record, master roadmap, and `INDEX.md` with run/artifact evidence.
5. Commit as `docs(xcodegen-m3): record production cutover evidence`.

After M3, M4 ongoing work is declarative-only: edit spec/xcconfig, run the manual generator workflow or local pinned script, commit the generated output, and let CI prove zero drift. A trusted write-token updater can be added separately, but PR validation remains read-only.
