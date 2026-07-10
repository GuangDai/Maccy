# Maccy declarative Xcode project generation research

> Date: 2026-07-10
>
> Repository baseline: `7da8ac6` (`c1-single-filter-source`)
>
> Scope: replace routine hand-editing of `Maccy.xcodeproj/project.pbxproj` with a declarative source and GitHub Actions generation/verification. This document does not implement the migration.

## Executive decision

Adopt **XcodeGen**, with a pinned `2.45.4` toolchain for the first migration, a repository-owned `project.yml`, and small `.xcconfig` files for the existing project/target build settings. Keep the generated `Maccy.xcodeproj` committed during adoption, but make `project.yml` and the `.xcconfig` files the only editable project-configuration sources. Every PR, push, and release must regenerate the project and fail on any diff.

This is the smallest maintainable answer for Maccy:

- XcodeGen directly models targets, configurations, settings, schemes, source/resource discovery, SDK and Swift package dependencies, plists, entitlements, and build scripts in YAML/JSON. It is explicitly designed to generate on CI. [XcodeGen README](https://github.com/yonaskolb/XcodeGen/tree/2.45.4#readme), [project-spec reference](https://github.com/yonaskolb/XcodeGen/blob/2.45.4/Docs/ProjectSpec.md)
- Its target source model supports directory discovery, exclusions, explicit build phases, compiler flags, and Xcode 16 synchronized folders. That covers Maccy's Swift, C++, ObjC++, headers, resources, and `.lproj` tree without a custom generator. [XcodeGen source specification](https://github.com/yonaskolb/XcodeGen/blob/2.45.4/Docs/ProjectSpec.md#sources)
- XcodeGen explicitly permits a generated project to remain committed as an adoption step and recommends running generation in CI. [XcodeGen FAQ](https://github.com/yonaskolb/XcodeGen/blob/2.45.4/Docs/FAQ.md#can-i-still-check-in-my-project)
- Tuist is capable but adds Swift manifests, its own dependency-install workflow, and a larger adoption surface. Its official migration guide acknowledges that existing projects require manual reconstruction and recommends migrating targets incrementally. That is disproportionate for one project with three targets. [Tuist Xcode-project migration guide](https://tuist.dev/en/docs/guides/features/projects/adoption/migrate/xcode-project)

Do **not** let a PR workflow automatically push generated changes. The ordinary drift check needs only `contents: read`; fork PR tokens are read-only, and executing PR code with a privileged `pull_request_target` token is a documented supply-chain risk. [GitHub fork-event security](https://docs.github.com/en/actions/reference/security/securely-using-pull-request-target), [GitHub token permissions](https://docs.github.com/actions/security-for-github-actions/security-guides/automatic-token-authentication)

If a one-click updater is desired, make it a separate, maintainer-only `workflow_dispatch` workflow with narrowly scoped `contents: write`. It must verify before committing and explicitly dispatch CI after pushing, because events created with the repository `GITHUB_TOKEN` generally do not start another workflow run. [GitHub `GITHUB_TOKEN` trigger semantics](https://docs.github.com/en/actions/concepts/security/github_token)

## Why this is worth doing in this repository

The current project is not a small static file:

- `Maccy.xcodeproj/project.pbxproj` is 2,319 lines.
- It defines three native targets (`Maccy`, `MaccyTests`, `MaccyUITests`), Debug/Release configurations at project and target levels, one shared scheme, one external test plan, ten remote Swift packages, SDK frameworks, source/resource phases, and eight localization variant groups.
- It carries the Swift 6 complete-concurrency settings, macOS 14 deployment target, an ObjC bridging header, ObjC++ and C++ compilation, C++17 at project level, entitlements, hardened runtime, signing settings, and hosted unit/UI-test settings.
- Since 2026-06-14, **45 commits** have touched the pbxproj. Two follow-up fixes are direct evidence of the failure mode: `b6653fc` fixed a wrong group-child UUID, and `d3ee28e` fixed a reused UUID collision. The project file is routine roadmap toil, not a rare configuration artifact.

The existing workflows and scripts all assume a committed project named `Maccy.xcodeproj` and scheme `Maccy`:

- `.github/workflows/macos26-arm-ci.yml` runs five build/test shards after lint.
- `.github/workflows/release.yml` calls `scripts/package-app.sh`, which directly passes `-project Maccy.xcodeproj -scheme Maccy`.
- The shared scheme references `Maccy.xctestplan`.
- `Maccy.xctestplan` contains the current generated-object identifiers for the app and both test targets.
- `Maccy.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` pins all ten package revisions.

Keeping the output committed initially avoids breaking all of those entry points at once while still ending hand-editing: humans edit `project.yml`; CI proves that the committed output was generated from it.

## Options compared

| Approach | Coverage for Maccy | Operational cost | Verdict |
|---|---|---|---|
| **XcodeGen YAML + generated xcodeproj** | Covers all three targets, build settings/xcconfig, source/resource phases, SDK frameworks, remote packages, shared scheme, plist and entitlements. It can reference the existing test plan. | One small spec, one pinned CLI, generation before validation. Current build/release commands can stay unchanged while output remains committed. | **Recommended.** Smallest full solution. |
| **Tuist Swift manifests** | Covers the same project graph and adds richer graph validation, build/test/caching workflows. Tuist supports external packages through `Tuist/Package.swift`. [Tuist dependencies](https://tuist.dev/en/docs/guides/features/projects/dependencies) | Adds `Tuist.swift`, `Project.swift`, `Tuist/Package.swift`, pinned Tuist installation, and Tuist-specific generation/install conventions. Official migration guidance says an existing project cannot be reliably auto-migrated and should be rebuilt target by target. [Tuist migration guide](https://tuist.dev/en/docs/guides/features/projects/adoption/migrate/xcode-project) | Viable, but too heavy for the current single-project/three-target graph. Revisit only if Maccy later becomes a multi-project/module graph and needs Tuist caching or graph tooling. |
| **Keep native project, convert groups to Xcode synchronized folders** | Automatically picks up files added/removed under selected directories and sharply reduces source-file pbxproj churn. Apple says buildable folders store only the folder path and minimize project-file diffs. [Xcode 16 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-16-release-notes), [file/folder management](https://developer.apple.com/documentation/xcode/managing-files-and-folders-in-your-xcode-project) | Still leaves targets, build settings, packages, SDK links, schemes, target membership exceptions, and test-plan references in the hand-edited project. It also changes the project format from the current object version 54 and requires careful membership exceptions. | Useful fallback or an XcodeGen output style, but not a declarative project-generation solution by itself. |

### Why not convert the app to a standalone Swift package

Apple's package manifest is excellent for reusable libraries and executable packages, and packages avoid `.xcodeproj`, but Maccy is a signed AppKit/SwiftUI application bundle with entitlements, hardened runtime, an app scheme, hosted unit tests, UI tests, asset catalogs, localizations, and release packaging. A package conversion would be an application-architecture migration rather than project-file automation. Apple also distinguishes packages as folder/manifest-based components rather than Xcode projects. [Apple: creating a standalone Swift package](https://developer.apple.com/documentation/xcode/creating-a-standalone-swift-package-with-xcode)

## Maccy-to-XcodeGen mapping

The migration spec must express the current semantics, not merely make a project that happens to compile.

| Current concern | Declarative representation and acceptance requirement |
|---|---|
| Project/configurations | `name: Maccy`, explicit Debug/Release configs, `defaultConfig: Debug`, explicit `xcodeVersion` and `projectFormat`. Do not rely on XcodeGen defaults that can change between releases. |
| App target | `type: application`, `platform: macOS`, deployment target `14.0`, exact bundle/version/signing/hardened-runtime settings, explicit plist and entitlements paths. |
| Unit/UI targets | `bundle.unit-test` and `bundle.ui-testing`, app target dependency, exact host/loader/test-target behavior, bundle identifiers, Swift 6 complete mode, and AppIntents SDK link. XcodeGen can derive `TEST_HOST`/`TEST_TARGET_NAME`, but the generated values must be compared with current `xcodebuild -showBuildSettings`; do not assume equivalence. [XcodeGen target settings](https://github.com/yonaskolb/XcodeGen/blob/2.45.4/Docs/ProjectSpec.md#target) |
| Swift 6/concurrency | Preserve `SWIFT_VERSION = 6.0` and `SWIFT_STRICT_CONCURRENCY = complete` for all targets. A generator migration must not loosen the repository's compile contract. |
| C++/ObjC++ bridge | Include `.cpp`, `.hpp`, `.h`, and `.mm` with their inferred types; preserve `Maccy/Maccy-Bridging-Header.h`, project/app `CLANG_CXX_LANGUAGE_STANDARD = gnu++17`, the UI-test target's explicit `gnu++14` override, `libc++`, ARC/modules, and header search behavior. Build success alone is insufficient: `MaccyTextProcessorTests` and the full unit suite remain required. |
| SDK frameworks | Explicit `sdk: Carbon.framework` and `sdk: AppIntents.framework` dependencies with current target membership. Do not rely on imports to produce implicit framework links. |
| Swift packages | Declare all ten URLs and the same requirement kinds: Sauce, SwiftHEXColors, KeyboardShortcuts, Sparkle, Settings, LaunchAtLogin-Modern, Defaults, fuse-swift, swift-async-algorithms, and swift-log. Link the correct product names (`LaunchAtLogin`, `Fuse`, `AsyncAlgorithms`, `Logging`, etc.) only to the app. XcodeGen supports major/minor/exact/range/branch/revision requirements. [XcodeGen Swift packages](https://github.com/yonaskolb/XcodeGen/blob/2.45.4/Docs/ProjectSpec.md#swift-package) |
| Package lock | Continue committing `Maccy.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. It is SwiftPM-owned state, not XcodeGen-owned output, and must survive regeneration. Apple recommends resolving dependencies in CI and describes using the resolved versions for reproducibility. [Apple: packages in CI](https://developer.apple.com/documentation/xcode/building-swift-packages-or-apps-that-use-them-in-continuous-integration-workflows) |
| Scheme | Generate the shared `Maccy` scheme from the spec with the existing build/run/test/profile/analyze/archive configurations and the test-plan reference. Schemes define those build actions, so parity is part of the migration contract. [Apple scheme documentation](https://developer.apple.com/documentation/xcode/customizing-the-build-schemes-for-a-project), [XcodeGen schemes](https://github.com/yonaskolb/XcodeGen/blob/2.45.4/Docs/ProjectSpec.md#scheme) |
| Test plan | Keep `Maccy.xctestplan` committed. XcodeGen explicitly **does not generate test-plan files**; it only references them, and target add/remove/rename can require an Xcode update. First generation must update/verify the app/unit/UI target identifiers and retain the `enable-testing` argument. [XcodeGen test-plan limitation](https://github.com/yonaskolb/XcodeGen/blob/2.45.4/Docs/ProjectSpec.md#test-plan), [Apple test-plan documentation](https://developer.apple.com/documentation/xcode/organizing-tests-to-improve-feedback) |
| Build phases | Preserve compile sources, link frameworks, and copy resources membership. The current empty `Embed Frameworks` phase can be intentionally dropped only if the migration commit records that it is semantically empty. XcodeGen supports pre-build, post-compile, and post-build scripts if future phases are needed. [XcodeGen build scripts](https://github.com/yonaskolb/XcodeGen/blob/2.45.4/Docs/ProjectSpec.md#build-script), [Apple build phases](https://developer.apple.com/documentation/xcode/customizing-the-build-phases-of-a-target) |
| App resources | Preserve Assets.xcassets, the Core Data model, `Write.caf`, all eight localization variant groups, and the unusual root `README.md in Resources` membership. Do not let a broad source glob silently omit README or add unrelated files. |
| Test fixtures | `MaccyTests/Fixtures/guy.jpeg` is currently a bundle resource. `heavy_text.txt` is deliberately loaded by `#filePath`-relative `FixtureLoader` and is not currently in Copy Bundle Resources. A broad `MaccyTests` source declaration must explicitly preserve that distinction. |
| File visibility vs build membership | Plists, entitlements, the bridging header, `.hpp` files, audit/config files, and source-only fixtures need explicit `buildPhase: none`, `fileGroups`, or exclusions as appropriate. "Visible in Xcode" and "compiled/copied" are separate requirements. |

### Localization is a migration trap

The current pbxproj contains 31 known regions/variant members, while the filesystem has 41 unique `.lproj` languages. The additional on-disk languages are:

`bn`, `ca`, `el`, `eo`, `fa`, `hi`, `id`, `pt`, `sv`, `ta`.

A naïve `sources: [Maccy]` declaration may add these ten locales to the app bundle. That is a user-visible behavior/package-content change and must not be smuggled into infrastructure migration. The first spec should reproduce the current 31-language membership with explicit exclusions. A separate BartyCrouch/Weblate localization audit can decide whether all on-disk locales should ship.

## Generated-output policy

### Commit the generated xcodeproj during adoption

Yes. Commit it at first, for these repository-specific reasons:

1. Existing CI, release packaging, and developer clone/open flows continue to work without an immediate bootstrap change.
2. The committed output gives code review a visible one-time migration diff and later generator-upgrade diffs.
3. `Maccy.xctestplan` contains target identifiers and XcodeGen does not generate it. Keeping output visible makes identifier drift detectable.
4. The SwiftPM lock currently lives inside the project workspace. Removing the whole generated directory from Git would also remove the lock unless the lock strategy is redesigned.
5. A zero-diff gate converts the duplicated artifact into a checked derivation: stale output cannot merge.

The project may be removed from Git later, but only after all workflows generate before using it, local bootstrap is documented, test-plan identifiers have remained stable through target changes, package-lock ownership is relocated or explicitly unignored, and generator upgrades have proven reproducible. There is no immediate value in taking that second step.

### Ownership rules

- Human-edited truth: `project.yml`, referenced `.xcconfig` files, package version requirements, and any small generation script/version file.
- XcodeGen-owned output: `project.pbxproj` and the shared scheme/workspace skeleton it writes.
- Xcode/SwiftPM-owned checked inputs: `Maccy.xctestplan` and `Package.resolved`.
- Forbidden after migration: direct pbxproj fixes to add/remove files, targets, packages, or settings. Make the declarative change and regenerate.
- Any Xcode UI edit that changes generated output must be translated back into the spec before commit.

## Version pinning and reproducibility

Use XcodeGen `2.45.4` as the evaluated migration baseline, not `brew install xcodegen` with an unbounded latest formula. The official release provides `xcodegen.zip`, and the release archive contains the binary plus its setting presets. [XcodeGen 2.45.4 release](https://github.com/yonaskolb/XcodeGen/releases/tag/2.45.4), [official archive script](https://github.com/yonaskolb/XcodeGen/blob/2.45.4/scripts/archive.sh)

The repository should record:

- exact version (`2.45.4` initially);
- official release URL;
- reviewed SHA-256 of the downloaded archive;
- `minimumXcodeGenVersion: 2.45.4` in the spec as a second guard (a minimum is not an exact pin);
- explicit `xcodeVersion`, `projectFormat`, development language, default configuration, setting-preset policy, and group ordering in `project.yml`.

The macOS 26 arm64 runner has Xcode and Homebrew but does not list XcodeGen or Tuist, so installation is required. GitHub documents `macos-26` as an arm64 hosted-runner label and permits installing additional software during a job. [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [macOS 26 image manifest](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md), [customizing hosted runners](https://docs.github.com/en/actions/how-tos/manage-runners/github-hosted-runners/customize-runners)

Do not use `xcodegen generate --use-cache` in the correctness gate. XcodeGen documents that the flag may skip generation when its cache considers inputs unchanged; a drift gate should always run an uncached generation. `--use-cache` remains acceptable for an optional local convenience command. [XcodeGen usage](https://github.com/yonaskolb/XcodeGen/tree/2.45.4#usage)

## Concrete workflow design

### 1. Shared repository script

Add one shell entry point (for example, `scripts/generate-xcodeproj.sh`) that:

1. downloads the pinned official XcodeGen archive if the exact binary is absent;
2. verifies the recorded SHA-256;
3. verifies `xcodegen --version` exactly;
4. runs uncached `xcodegen generate --spec project.yml` from the repository root;
5. never resolves or rewrites package versions itself;
6. never deletes `Package.resolved` or `Maccy.xctestplan`.

This avoids duplicating install/generate logic in CI and release YAML. It is shell/YAML work and does not require changing `.swiftlint.yml`; any Swift helper introduced later must follow the repository's default/strict SwiftLint policy.

### 2. Required drift job in the existing CI workflow

Prefer a separate job in `.github/workflows/macos26-arm-ci.yml` named `Generated Xcode project`, with `permissions: contents: read`, `runs-on: macos-26`, and a short timeout. Make `test-shards` depend on both the existing lint job and this job.

Conceptual steps:

```yaml
project-generation:
  name: Generated Xcode project
  runs-on: macos-26
  timeout-minutes: 8
  permissions:
    contents: read
  steps:
    - uses: actions/checkout@v6
    - name: Generate project (pinned XcodeGen)
      run: scripts/generate-xcodeproj.sh
    - name: Verify generator is repeatable
      run: |
        cp -R Maccy.xcodeproj "$RUNNER_TEMP/first.xcodeproj"
        scripts/generate-xcodeproj.sh
        diff -ru "$RUNNER_TEMP/first.xcodeproj" Maccy.xcodeproj
    - name: Verify committed output
      run: git diff --exit-code -- Maccy.xcodeproj
    - name: Verify Xcode can parse project and list shared scheme
      run: xcodebuild -list -json -project Maccy.xcodeproj
```

The double generation is intentional: exact version pinning limits drift, while a same-run comparison proves the current spec/generator is repeatable instead of merely matching a previously committed artifact. The Git diff is the zero-diff gate; Git documents that `--exit-code` returns 1 when differences exist and 0 when none exist. [Git `diff --exit-code`](https://git-scm.com/docs/git-diff#Documentation/git-diff.txt---exit-code) If it fails, print `git diff -- Maccy.xcodeproj` and upload the patch/log as an artifact for diagnosis.

Do not give this job `contents: write`, do not use `pull_request_target`, and do not silently repair PR branches. A failed check should say: update `project.yml`, run/dispatch regeneration, and commit the result.

Do not path-filter a separate required workflow down to `project.yml`/source paths. GitHub notes that a required workflow skipped by path filtering can remain pending and block merge. Keeping the small job inside the existing CI also ensures every source add/remove is checked. [GitHub workflow path-filter behavior](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#onpushpull_requestpull_request_targetpathspaths-ignore)

### 3. Build/test jobs

After the zero-diff job passes, the existing shards can continue building the committed `Maccy.xcodeproj`: the gate has proved it byte-for-byte equals fresh generated output. There is no need to install XcodeGen independently in all five shards.

Change only the dependency shape:

```yaml
test-shards:
  needs: [lint, project-generation]
```

The current full CI remains the semantic proof. A clean zero-diff proves freshness, not that the spec preserved build behavior.

### 4. Release workflow

Run the same generation and zero-diff check in `.github/workflows/release.yml` immediately after checkout and before `scripts/package-app.sh`. This protects manual dispatches and tags that did not pass the branch gate. The packaging script itself can remain unchanged because the generated output retains the same project and scheme names.

The release job must fail rather than publish from stale output.

### 5. Optional maintainer updater workflow

A separate `workflow_dispatch` workflow may accept a trusted branch input, check out that branch, run generation, run the parse/repeatability check, commit only `project.yml`-derived project output, and push if there is a diff. Requirements:

- restrict it to maintainers/trusted branches;
- grant only that job `contents: write`;
- refuse detached PR merge refs and forks;
- use a fixed commit message such as `chore(project): regenerate Maccy.xcodeproj`;
- explicitly dispatch `macOS 26 ARM CI` after the push, or use a GitHub App token whose events can trigger CI;
- do not use it as the PR validation workflow.

This updater is convenience, not the correctness boundary. The read-only zero-diff check remains authoritative.

## Migration sequence and gates

Treat the initial rewrite as a standalone infrastructure step, not as part of a behavioral roadmap commit.

### M0 — freeze the current contract on CI

Capture artifacts from the current committed project on the macOS runner:

- `xcodebuild -list -json`;
- `xcodebuild -showBuildSettings` for all three targets/configurations;
- source, resource, framework, and target-dependency membership;
- shared scheme XML and `Maccy.xctestplan` target identifiers/options;
- `Package.resolved` pins;
- current `Info.plist`/entitlements paths and final built app resource/localization inventory.

This is the evidence used to review the one-time full pbxproj rewrite.

### M1 — generate beside the legacy project

Create the spec and xcconfigs, initially generate a differently named project (for example `Maccy-Generated.xcodeproj`), and compare it against the M0 inventory. Avoid changing application code.

Explicitly resolve the known exceptions:

- README is an app resource;
- `guy.jpeg` is a unit-test resource but `heavy_text.txt` is not;
- ObjC++/C++/bridging header settings match;
- all ten package requirements/products match and all locked revisions remain;
- AppIntents/Carbon target membership matches;
- only the current 31 shipping languages are included;
- scheme actions and the `enable-testing` test-plan argument match;
- test-plan target identifiers point at the generated targets.

### M2 — semantic CI equivalence

On the generated project, run the full macOS 26 ARM workflow, including all unit, UI, and performance shards, plus a release packaging dry run. The repository has no local Xcode environment, so runner evidence is the only compile/test gate.

Also compare resolved build settings rather than comparing only YAML to pbxproj text. XcodeGen applies setting presets unless configured otherwise, and its documentation explains that presets, setting groups, inline settings, xcconfigs, and SDK defaults form a precedence chain. [XcodeGen build-setting behavior](https://github.com/yonaskolb/XcodeGen/blob/2.45.4/Docs/Usage.md#configuring-build-settings)

### M3 — one-time replacement commit

Replace `Maccy.xcodeproj` with the generated output in one dedicated commit, add the pinned generation entry point and zero-diff job, and record intentional structural differences such as object/project format, generated UUID/order, and removal of the empty Embed Frameworks phase.

The initial commit is expected to rewrite most of `project.pbxproj`; **do not** demand zero diff against the legacy file before this cutover. Demand semantic parity and then establish zero diff from the newly generated baseline onward.

### M4 — ongoing invariant

Every later change follows this order:

1. change source files and/or `project.yml`/xcconfig;
2. regenerate with the pinned tool;
3. commit declarative input and generated output together;
4. CI regenerates again, proves repeatability and zero diff, then runs existing tests.

Tool upgrades are isolated commits: update the version and checksum, regenerate, review the complete project diff, run the full CI and packaging gates, then merge.

## Risks and mitigations

| Risk | Why it matters here | Required mitigation |
|---|---|---|
| Whole-file first diff | Generated UUIDs, ordering, project format, and setting presets will rewrite much of a 2,319-line legacy file. | One isolated migration commit; review M0/M1 semantic inventories and full runner gates, not cosmetic line similarity. |
| Generator/default drift | XcodeGen defaults such as project format and setting presets evolve. | Pin exact binary + checksum and explicit project options; upgrade only in dedicated commits. |
| Non-repeatable identifiers | Test plan and scheme contain target identifiers; unexpected churn breaks references and destroys useful diffs. | Generate twice in CI, compare output, keep test plan committed, and verify its identifiers on every target change. |
| Test plan is outside generator ownership | XcodeGen can only reference `.xctestplan`. | Preserve it as an explicit checked input; add a verification script that all referenced target names/IDs exist in the generated project. |
| Package requirement or lock drift | Ten packages include different major/minor constraints and renamed products. | Transcribe requirement kinds exactly, preserve/commit `Package.resolved`, and use normal `xcodebuild` package resolution/build as a CI gate. |
| Broad file discovery changes membership | Maccy contains support files, unusual README resource membership, source-relative fixture data, and unshipped localizations. | Start with explicit excludes/inclusions; compare source/resource membership and built bundle inventory. |
| Localization expansion | Ten `.lproj` languages exist on disk but are not in current variant groups. | Preserve current 31 at migration; audit/ship extras separately. |
| C++/ObjC++ regression hidden by Swift-only checks | Fingerprinting and UTF-8 validation depend on the bridge. | Preserve build settings/header paths and require focused processor tests plus full unit CI. |
| CI auto-commit security/recursion | PR code should not run with a write token; `GITHUB_TOKEN` pushes do not automatically produce the expected follow-up run. | Read-only PR drift gate; optional trusted manual updater with explicit post-push dispatch. |
| Required check skipped by path filters | Skipped workflows can remain pending. | Put the job in the existing required workflow or avoid event-level path filters. |
| Output removed too early | Current build/release commands and SwiftPM lock location assume the xcodeproj exists. | Keep generated output committed until all consumers and lock ownership are deliberately migrated. |

## Acceptance criteria

The work is complete only when all of the following are proven on current state:

- A pinned, checksummed XcodeGen version generates `Maccy.xcodeproj` from committed declarative inputs.
- Two uncached, in-place generations in one runner job produce identical project directories.
- Fresh generation leaves `git diff --exit-code -- Maccy.xcodeproj` clean.
- All three targets and all Debug/Release resolved build settings match the recorded contract, including Swift 6 complete concurrency and C++/ObjC++ settings.
- All ten Swift package requirements/products and `Package.resolved` pins are preserved.
- Source, resource, framework, fixture, model, localization, Info.plist, entitlements, and bridging-header membership is explicitly accounted for.
- The shared scheme retains build/run/test/profile/analyze/archive behavior.
- `Maccy.xctestplan` still selects both test targets and passes `enable-testing`, with valid generated identifiers.
- The full macOS 26 ARM CI and release packaging dry run are green from the generated project.
- PR/push validation is read-only; release also performs generation/drift verification.
- Direct pbxproj editing is documented as generated-output drift and rejected by CI.

## M0 completion evidence (2026-07-11)

M0 is complete at `d632790`. The read-only capture workflow is
`.github/workflows/xcodeproj-contract.yml`, backed by
`scripts/capture-xcodeproj-contract.sh`.

- The successful contract run is [GitHub Actions run 29125075137](https://github.com/GuangDai/Maccy/actions/runs/29125075137). Its `xcodeproj-contract-29125075137-1` artifact contains 23 files; both `git-status-before.txt` and `git-status-after.txt` are empty, the clean Debug build ends in `BUILD SUCCEEDED`, and the log contains no `warning:`, `error:`, `TEST FAILED`, or `BUILD FAILED` lines.
- The default-branch semantic gate is [macOS 26 ARM CI run 29125209517](https://github.com/GuangDai/Maccy/actions/runs/29125209517): lint, unit, `ui-1`, `ui-2`, `perf-text`, and `perf-image` all passed. `ui-2` required the single permitted failed-job rerun after the documented runner-contention `testPin` flake; no product or test change was made for it.
- The runner was macOS 26.4 arm64 with Xcode 26.5 (`17F42`). The captured project lists Debug/Release, targets `Maccy`, `MaccyTests`, and `MaccyUITests`, and shared project scheme `Maccy` (plus package schemes reported by Xcode).
- All six target/configuration build-setting captures retain deployment target 14.0, Swift 6.0, and `SWIFT_STRICT_CONCURRENCY=complete`. The app and unit-test targets resolve `CLANG_CXX_LANGUAGE_STANDARD=gnu++17`; the UI-test target retains its `gnu++14` override. App plist, entitlements, bridging header, hosted-unit-test path, and UI-test target name match the legacy project.
- The app target has four build phases and ten direct package-product dependencies; both test targets have three build phases and one app dependency. The resolved graph has 11 pins because `swift-collections` is a transitive dependency.
- The first capture run exposed a real stale-lock invariant: Xcode 26.5 added `swift-collections` 1.6.0 and changed `Package.resolved`'s `originHash`. Commit `d632790` records that canonical graph; the successful capture proves a subsequent clean build leaves the repository unchanged.
- The test plan still references app UUID `DAEE38421E3DBEB100DD2966`, unit UUID `DA360DAF1E3DF137005C6F6B`, and UI UUID `DA0EE7B5204657830025FC60`, and retains the `enable-testing` argument. The shared scheme uses Debug for test/run/analyze and Release for profile/archive as before.
- The filesystem contains 41 source languages, while the built app has exactly the existing 31 top-level localization directories. The ten intentionally unshipped languages remain `bn`, `ca`, `el`, `eo`, `fa`, `hi`, `id`, `pt`, `sv`, and `ta`. The bundle inventory contains 442 files and confirms `README.md`, `Write.caf`, `Assets.car`, and App Intents metadata.
- Permanent captured-input hashes for M1 comparison are:
  - `project.pbxproj`: `dbb4df2a5f4aa15beec1fe55b2bbde7935afcd3a65028a74a6e1b4168b39e9e3`
  - shared `Maccy.xcscheme`: `0cb88c0244fc46bf27ab280aa0b41c742b6d4814cc4adda0fb53b51799b16761`
  - `Maccy.xctestplan`: `42ea0871439f07c208b72173402714ecf2875861f96ff6502ae56d8dbe6ca2c6`
  - `Package.resolved`: `b876894d2ffb9a9f73fea94ce070ddf555f80bb5e2486ea0c3e6ee7798385144`

M1 may now generate a side-by-side project. It must use this captured semantic inventory rather than line-diffing generated UUID/order against the legacy pbxproj.

## Primary sources

- [XcodeGen 2.45.4 README and installation/CI overview](https://github.com/yonaskolb/XcodeGen/tree/2.45.4#readme)
- [XcodeGen 2.45.4 project specification](https://github.com/yonaskolb/XcodeGen/blob/2.45.4/Docs/ProjectSpec.md)
- [XcodeGen FAQ: committing projects and CI generation](https://github.com/yonaskolb/XcodeGen/blob/2.45.4/Docs/FAQ.md)
- [XcodeGen 2.45.4 release](https://github.com/yonaskolb/XcodeGen/releases/tag/2.45.4)
- [Tuist: migrating an existing Xcode project](https://tuist.dev/en/docs/guides/features/projects/adoption/migrate/xcode-project)
- [Tuist: project generation](https://tuist.dev/en/docs/guides/features/projects)
- [Tuist: installation and deterministic version pinning](https://tuist.dev/en/docs/guides/install-tuist)
- [Apple: Xcode 16 buildable/synchronized folders](https://developer.apple.com/documentation/xcode-release-notes/xcode-16-release-notes)
- [Apple: managing files and folders in an Xcode project](https://developer.apple.com/documentation/xcode/managing-files-and-folders-in-your-xcode-project)
- [Apple: Xcode command-line tool reference](https://developer.apple.com/documentation/xcode/xcode-command-line-tool-reference)
- [GitHub-hosted macOS runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [GitHub Actions token/security guidance](https://docs.github.com/en/actions/reference/security/securely-using-pull-request-target)
