# XcodeGen M2 semantic CI equivalence plan

> **For agentic workers:** execute one task/commit at a time. The legacy `Maccy.xcodeproj` remains the production input throughout M2.

**Goal:** Prove the deterministic side-by-side XcodeGen project is not merely buildable but semantically equivalent for Maccy's full test matrix and release packaging path.

**Architecture:** Add a checked side-by-side test plan whose target identifiers match the deterministic generated project and retain the canonical `enable-testing` launch argument. A runner-side verifier derives target IDs from the freshly generated pbxproj and rejects any stale plan/scheme reference. Extend the existing read-only generated-project workflow so its validated generated artifact feeds the same five unit/UI/performance shards and a Release packaging dry run. Do not change the normal CI/release project inputs until M3.

**Tech stack:** XcodeGen 2.45.4, Xcode 26.5, Bash, jq/plutil, GitHub Actions, `xcodebuild`, macOS 26 arm64.

## Frozen inputs and invariants

- M1 artifact/run: `29128236363`; generated target IDs are deterministic across the two uncached generations:
  - `Maccy`: `96606D5FD79240E7FA5BBD83`
  - `MaccyTests`: `48CB1C6F86B4EDE284AA2C51`
  - `MaccyUITests`: `0D54D793B68730ADB36C0C3A`
- `Maccy.xctestplan`, `Maccy.xcodeproj`, and the canonical `Package.resolved` remain byte-identical in M2.
- The side-by-side plan must keep the `enable-testing` command-line argument because test-mode storage/notification behavior depends on it.
- The generated scheme must reference the generated plan and retain both test targets.
- Every shard uses `Maccy-Generated.xcodeproj` and the generated scheme; none may silently fall back to the legacy project.
- Release verification is a dry run only: build/package/checksum/upload artifact, never publish a GitHub Release.
- The workflow remains `workflow_dispatch` + `contents: read`; no automatic commits or write token in M2.

---

## Task 1: Attach a valid generated-target test plan

**Files:**

- Create: `Maccy-Generated.xctestplan`
- Create: `scripts/verify-generated-test-plan.sh`
- Modify: `project.yml`

1. Copy the canonical plan semantics into `Maccy-Generated.xctestplan`, changing only its three target identifiers and `containerPath` values to the M1 generated project contract.
2. Add the plan as a non-build file group and reference it from the generated scheme with `defaultPlan: true`, retaining the explicit test targets.
3. Add a verifier that converts the fresh pbxproj with `plutil`, derives the three `PBXNativeTarget` IDs by name, compares them with the plan, proves `enable-testing` is present, and proves the scheme references the generated plan.
4. Run `jq -e` on the plan and `bash -n` on the verifier.
5. Commit as `build(xcodegen-m2): attach generated test plan`.

## Task 2: Make test-plan validity an M2 generation gate

**Files:**

- Modify: `.github/workflows/xcodeproj-generated.yml`

1. Run the verifier after the second generation/package-lock seed.
2. Capture verifier output with the existing generated-project evidence.
3. Add the step outcome to the final generation gate.
4. Continue proving repeatability, legacy/generated graph/settings parity, bundle resources, package pins, and unchanged canonical inputs.
5. Commit as `ci(xcodegen-m2): verify generated test plan`.

## Task 3: Run semantic test and packaging equivalence

**Files:**

- Modify: `.github/workflows/xcodeproj-generated.yml`

1. Add a five-entry matrix matching `macos26-arm-ci.yml`: `unit`, `ui-1`, `ui-2`, `perf-text`, and `perf-image`, with the same only/skip lists, corpus acquisition, runner-noise filtering, expected fault-injection allowlist, result bundles, and blocking semantics.
2. Each shard checks out the same commit, downloads the validated generated-project artifact into the repository root, asserts the generated pbxproj/test plan exist, and runs `xcodebuild test` with `PROJECT=Maccy-Generated.xcodeproj`.
3. Add a Release package dry-run job that downloads the same artifact and invokes `scripts/package-app.sh` with the generated project, isolated derived-data/package directories, signing disabled, and no publish step.
4. Scan the package log for warnings/errors/failures and upload the zip/checksum/log as evidence.
5. Keep this manual M2 workflow separate from normal CI/release until M3.
6. Commit as `ci(xcodegen-m2): test and package generated project`.

## Task 4: Runner iteration and acceptance

1. Wait for the current default-branch workflow to finish; do not overlap workflow runs.
2. Dispatch `Validate Generated Xcode Project` once on the M2 branch.
3. On failure, inspect job conclusions first and failed-log tails second; fix one semantic category per commit. Do not rerun known 3-second UI contention or microbenchmark RSD flakes.
4. Acceptance requires:
   - repeatable generation and all M1 parity gates green;
   - fresh target-ID/test-plan/scheme verification green;
   - complete unit, both UI, and both performance shards green or a single documented repository-known contention flake classified without rerun;
   - generated Release app zip + SHA-256 dry run green and warning-free;
   - canonical legacy project/test plan/package lock unchanged.
5. Record the run/artifact and commit evidence in this plan, the XcodeGen research document, `INDEX.md`, and the master roadmap.
6. Commit as `docs(xcodegen-m2): record semantic CI evidence`.

M3 begins only after these gates are evidence-backed. M3 owns the isolated `Maccy.xcodeproj` replacement, canonical test-plan ID update, normal CI/release zero-diff generation gates, and the no-hand-edit ownership rule.
