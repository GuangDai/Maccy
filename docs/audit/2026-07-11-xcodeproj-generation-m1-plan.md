# Side-by-side XcodeGen Project (M1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Generate a deterministic `Maccy-Generated.xcodeproj` beside the legacy project and prove its project graph, resolved build settings, package graph, resources, and app build match the M0 contract without changing any production build entry point.

**Architecture:** `project.yml` and repository-owned `.xcconfig` files describe the three-target graph. A single shell entry point downloads the exact reviewed XcodeGen release, verifies its official SHA-256 digest, and generates uncached output. A manual read-only workflow generates twice under `runner.temp`, compares both outputs, compares the generated project against the live legacy project, clean-builds the generated app, and uploads all evidence. The committed legacy project remains authoritative until M2/M3.

**Tech Stack:** XcodeGen 2.45.4, YAML, xcconfig, Bash, jq/plutil, GitHub Actions, Xcode 26.5 on macOS 26 arm64.

## Frozen inputs

- XcodeGen version: `2.45.4`
- Release URL: `https://github.com/yonaskolb/XcodeGen/releases/download/2.45.4/xcodegen.zip`
- Official and independently verified SHA-256: `090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef`
- M0 semantic baseline: `docs/audit/2026-07-10-xcodeproj-generation-research.md#M0-completion-evidence-2026-07-11`
- Legacy input commit for M0: `d632790`
- Generated project name: `Maccy-Generated.xcodeproj`
- Production project/scheme remain `Maccy.xcodeproj` / `Maccy` throughout M1.

## Red lines

- Do not replace, regenerate, or hand-edit `Maccy.xcodeproj` in M1.
- Do not change application code, package requirements, target names, product names, bundle identifiers, shipping localizations, test-plan contents, or user-visible behavior.
- Do not use floating Homebrew installation or XcodeGen cache mode.
- Do not auto-commit from pull-request code and do not grant write permissions.
- Do not call M1 complete merely because the generated app builds; graph/settings/resource parity must also pass.

---

### Task 1: Pinned generator entry point

**Files:**

- Create: `scripts/generate-xcodeproj.sh`

- [x] **Step 1: Add an exact-version installer/generator**

The script must:

1. accept `SPEC`, `PROJECT_ROOT`, `OUTPUT_ROOT`, and `XCODEGEN_HOME` overrides;
2. download only the frozen release URL when the exact binary is absent;
3. verify the frozen SHA-256 before extraction;
4. verify `xcodegen --version` is exactly `2.45.4`;
5. run uncached `xcodegen generate --spec "$SPEC" --project-root "$PROJECT_ROOT" --project "$OUTPUT_ROOT"`;
6. assert `$OUTPUT_ROOT/Maccy-Generated.xcodeproj/project.pbxproj` exists;
7. never write into the legacy project.

- [x] **Step 2: Verify shell syntax and failure behavior locally**

Run `bash -n scripts/generate-xcodeproj.sh` and a checksum-negative test against a fake archive. Do not execute the macOS binary locally.

- [x] **Step 3: Commit**

Commit as `ci(xcodegen-m1): pin project generator toolchain`.

---

### Task 2: Declarative project contract

**Files:**

- Create: `project.yml`
- Create: `Config/Project-Common.xcconfig`
- Create: `Config/Project-Debug.xcconfig`
- Create: `Config/Project-Release.xcconfig`
- Create: `Config/Maccy-Common.xcconfig`
- Create: `Config/Maccy-Debug.xcconfig`
- Create: `Config/Maccy-Release.xcconfig`
- Create: `Config/MaccyTests-Common.xcconfig`
- Create: `Config/MaccyTests-Debug.xcconfig`
- Create: `Config/MaccyTests-Release.xcconfig`
- Create: `Config/MaccyUITests-Common.xcconfig`
- Create: `Config/MaccyUITests-Debug.xcconfig`
- Create: `Config/MaccyUITests-Release.xcconfig`

- [x] **Step 1: Encode project/configuration options explicitly**

Use `name: Maccy-Generated`, Debug/Release types, `defaultConfig: Debug`, `developmentLanguage: en`, macOS 14.0, explicit Xcode/project format, stable group ordering, and `minimumXcodeGenVersion: 2.45.4`. Disable setting presets and transitive implicit linking; every setting relied on by M0 must come from the checked spec/xcconfigs or the SDK.

- [x] **Step 2: Encode the package graph exactly**

Declare all ten direct packages with the same URL and requirement kind/minimum as the legacy project. Link exactly these products to `Maccy`: `Sauce`, `SwiftHEXColors`, `KeyboardShortcuts`, `Sparkle`, `Settings`, `LaunchAtLogin`, `Defaults`, `Fuse`, `AsyncAlgorithms`, and `Logging`. Seed the generated workspace with the committed canonical `Package.resolved` before Xcode resolution.

- [x] **Step 3: Encode the three targets and framework dependencies**

Preserve target/product types, target dependencies, AppIntents membership on all three targets, Carbon membership only on the app, hosted unit-test settings, UI-test target settings, Swift 6 complete concurrency, ObjC bridging header, C++17/app+unit behavior, UI-test C++14 override, plist/entitlements paths, versions, signing/hardened-runtime settings, and bundle identifiers.

- [x] **Step 4: Encode source/resource membership without localization expansion**

Use directory discovery only with explicit exclusions. Preserve:

- app Swift/C++/ObjC++ sources and headers;
- Assets, `Write.caf`, `Knock.caf`, all eight variant groups, root `README.md`, `LICENSE`, and `appcast.xml` resources;
- the unreferenced legacy `History.xcdatamodeld`, `Storage.xcdatamodeld`, and `Processor/third_party/LICENSE-xxhash.txt` as visible non-build files, not newly copied resources;
- `guy.jpeg` as a unit-test resource;
- `heavy_text.txt` as tracked/source-relative only, not a bundle resource;
- plist, entitlements, bridging header, and configuration files as visible non-build files;
- exactly the current 31 shipping app languages, excluding `bn`, `ca`, `el`, `eo`, `fa`, `hi`, `id`, `pt`, `sv`, and `ta` in all three localization subtrees.

- [x] **Step 5: Encode the shared scheme without mutating the canonical test plan**

Generate shared `Maccy` build/run/profile/analyze/archive actions. M1 may initially omit the test-plan reference from the generated scheme; valid generated-target identifiers and a side-by-side test-plan copy are a dedicated M2 prerequisite. The canonical `Maccy.xctestplan` must remain byte-identical in M1.

- [x] **Step 6: Commit**

Commit as `build(xcodegen-m1): describe side-by-side project`.

---

### Task 3: Machine-readable parity verifier

**Files:**

- Create: `scripts/compare-xcodeproj-contracts.sh`

- [x] **Step 1: Compare project graph and build membership**

Convert both pbxproj files to JSON and compare normalized sets for:

- three target names/types;
- target dependencies;
- source/resource/framework build-phase membership;
- ten package requirements and ten linked products;
- known regions and variant-group members.

Allow only intentional structural differences: project name/path, generated UUIDs/order, project format/object version, and removal of the empty Embed Frameworks phase.

- [x] **Step 2: Compare resolved build settings**

For all three targets and Debug/Release, call `xcodebuild -showBuildSettings -json` for legacy and generated projects. Normalize project-root/output-path values, then compare the M0-critical allowlist: deployment/SDK, Swift/concurrency, C/C++/ObjC, optimization/config conditions, plist/entitlements/bridging header, bundle/product/version, signing/hardened runtime, runpaths/framework paths, test host/loader/target, asset catalog, dead stripping, modules/ARC, and warning settings.

- [x] **Step 3: Emit actionable evidence**

Write normalized JSON and unified diffs into a caller-provided output directory. Any non-allowlisted semantic difference exits nonzero.

- [x] **Step 4: Verify Bash syntax and commit**

Run `bash -n` and commit as `test(xcodegen-m1): compare generated project contract`.

---

### Task 4: Side-by-side generation workflow

**Files:**

- Create: `.github/workflows/xcodeproj-generated.yml`

- [x] **Step 1: Add manual read-only workflow**

The `workflow_dispatch` job runs on `macos-26`, arm64, with `contents: read`. It must:

1. generate into two fresh runner-temp directories;
2. seed both generated workspaces with canonical `Package.resolved`;
3. compare both full project directories for repeatability;
4. run the parity verifier against the first project;
5. run `xcodebuild -list -json` on the generated project;
6. clean-build generated target `Maccy` with signing disabled;
7. assert the canonical test plan, legacy project, and package lock are unchanged;
8. capture generated pbxproj JSON, six build-setting JSON files, bundle/resource/localization inventories, generator version/checksum, and all parity diffs;
9. upload the evidence artifact even on failure.

- [ ] **Step 2: Commit and register the workflow**

Commit as `ci(xcodegen-m1): validate side-by-side project`. Because GitHub only dispatches workflows registered on the default branch, land the passive workflow before its first dispatch.

- [ ] **Step 3: Dispatch once and iterate from runner evidence**

Do not overlap runs. On failure, inspect job status first and the log tail second. Fix one semantic category per commit; preserve the generated artifact from each run for comparison.

---

### Task 5: M1 acceptance and handoff

- [ ] Two uncached generations are byte-for-byte identical.
- [ ] The generated project has exactly the three expected targets and one shared `Maccy` scheme.
- [ ] Normalized source/resource/framework/package/target-dependency membership matches M0.
- [ ] All six critical resolved build-setting comparisons pass.
- [ ] A clean generated `Maccy` app build succeeds with no warnings/errors.
- [ ] The built app retains the 31-language set and key resources from M0.
- [ ] `Maccy.xcodeproj`, `Maccy.xctestplan`, and canonical `Package.resolved` remain unchanged.
- [ ] Full legacy macOS 26 ARM CI remains green.
- [ ] Record run/artifact evidence in the research document and index this plan.

M2 begins only after every checkbox above is supported by runner evidence. M2 owns generated test-plan identifiers, full unit/UI/performance execution on the generated project, and release packaging parity.
