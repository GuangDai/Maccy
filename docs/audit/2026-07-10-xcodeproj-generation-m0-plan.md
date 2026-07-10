# Xcode Project Contract Capture (M0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture the current committed Xcode project's semantic contract on the macOS 26 ARM runner before introducing XcodeGen.

**Architecture:** A repository script performs read-only `xcodebuild` and filesystem inspection into a caller-provided fresh output directory. A manual, read-only GitHub Actions workflow runs the script, rejects repository drift, and uploads the contract as an artifact for the later XcodeGen parity comparison.

**Tech Stack:** Bash, `xcodebuild`, `plutil`, GitHub Actions, macOS 26 arm64.

## Global Constraints

- Do not generate or replace `Maccy.xcodeproj` in M0.
- Do not change product code, build settings, test-plan contents, package requirements, or shipping localizations.
- Run only on `macos-26` / `arm64`; this repository has no local Xcode toolchain.
- Keep workflow permissions at `contents: read` and prove the capture leaves `git diff` clean.
- Preserve Swift 6.0 complete strict concurrency and macOS 14.0 deployment settings as captured evidence.

---

### Task 1: Repository-owned contract capture

**Files:**

- Create: `scripts/capture-xcodeproj-contract.sh`

**Interfaces:**

- Consumes: optional `PROJECT`, `SCHEME`, `CONFIGURATION`, `DESTINATION`, `DERIVED_DATA`, and `OUTPUT_DIR` environment variables.
- Produces: a fresh directory containing diagnostics, project/target build settings, source project inputs, a Debug build log, bundle inventories, and SHA-256 checksums.

- [ ] **Step 1: Add the read-only capture script**

```bash
#!/usr/bin/env bash
set -euo pipefail

PROJECT="${PROJECT:-Maccy.xcodeproj}"
SCHEME="${SCHEME:-Maccy}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DESTINATION="${DESTINATION:-platform=macOS,arch=arm64}"
TEMP_ROOT="${TMPDIR:-/tmp}"
DERIVED_DATA="${DERIVED_DATA:-$TEMP_ROOT/MaccyContractDerivedData}"
OUTPUT_DIR="${OUTPUT_DIR:-$TEMP_ROOT/MaccyXcodeProjectContract}"

if [[ -e "$OUTPUT_DIR" ]]; then
  echo "Contract output already exists: $OUTPUT_DIR" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

git rev-parse HEAD > "$OUTPUT_DIR/git-head.txt"
git status --short > "$OUTPUT_DIR/git-status-before.txt"
xcodebuild -version > "$OUTPUT_DIR/xcode-version.txt"
sw_vers > "$OUTPUT_DIR/macos-version.txt"
uname -m > "$OUTPUT_DIR/architecture.txt"
xcodebuild -list -json -project "$PROJECT" > "$OUTPUT_DIR/project-list.json"
plutil -convert json -o "$OUTPUT_DIR/project.pbxproj.json" "$PROJECT/project.pbxproj"

for configuration in Debug Release; do
  for target in Maccy MaccyTests MaccyUITests; do
    xcodebuild \
      -project "$PROJECT" \
      -target "$target" \
      -configuration "$configuration" \
      -showBuildSettings \
      -json \
      CODE_SIGNING_ALLOWED=NO \
      > "$OUTPUT_DIR/build-settings-$target-$configuration.json"
  done
done

cp "$PROJECT/xcshareddata/xcschemes/Maccy.xcscheme" "$OUTPUT_DIR/Maccy.xcscheme"
cp Maccy.xctestplan "$OUTPUT_DIR/Maccy.xctestplan"
cp "$PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" "$OUTPUT_DIR/Package.resolved"

find Maccy -type d -name '*.lproj' -print | LC_ALL=C sort \
  > "$OUTPUT_DIR/filesystem-localizations.txt"
git ls-files Maccy MaccyTests MaccyUITests | LC_ALL=C sort \
  > "$OUTPUT_DIR/tracked-project-files.txt"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  clean build \
  2>&1 | tee "$OUTPUT_DIR/build.log"

app="$DERIVED_DATA/Build/Products/$CONFIGURATION/Maccy.app"
test -d "$app"
find "$app" -type f -print | sed "s#^$app/##" | LC_ALL=C sort \
  > "$OUTPUT_DIR/app-bundle-files.txt"
find "$app/Contents/Resources" -type d -name '*.lproj' -print \
  | sed "s#^$app/Contents/Resources/##" | LC_ALL=C sort \
  > "$OUTPUT_DIR/app-bundle-localizations.txt"

shasum -a 256 \
  "$PROJECT/project.pbxproj" \
  "$PROJECT/xcshareddata/xcschemes/Maccy.xcscheme" \
  Maccy.xctestplan \
  "$PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
  > "$OUTPUT_DIR/input-sha256.txt"

git status --short > "$OUTPUT_DIR/git-status-after.txt"
```

- [ ] **Step 2: Mark executable and verify shell syntax locally**

Run: `chmod +x scripts/capture-xcodeproj-contract.sh && bash -n scripts/capture-xcodeproj-contract.sh`

Expected: exit 0 with no output. Do not execute the script locally because Xcode is unavailable.

- [ ] **Step 3: Commit the capture script**

```bash
git add scripts/capture-xcodeproj-contract.sh
git commit -m "ci(xcodegen-m0): capture current Xcode project contract"
```

### Task 2: Manual contract artifact workflow

**Files:**

- Create: `.github/workflows/xcodeproj-contract.yml`

**Interfaces:**

- Consumes: any branch selected through `workflow_dispatch`.
- Produces: `xcodeproj-contract-${{ github.run_id }}-${{ github.run_attempt }}` artifact and a hard failure if capture mutates the repository.

- [ ] **Step 1: Add the manual read-only workflow**

```yaml
name: Capture Xcode Project Contract

on:
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: xcodeproj-contract-${{ github.ref }}
  cancel-in-progress: false

jobs:
  capture:
    name: Capture current project contract
    runs-on: macos-26
    timeout-minutes: 30
    env:
      FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: "true"
      OUTPUT_DIR: ${{ runner.temp }}/xcodeproj-contract
      DERIVED_DATA: ${{ runner.temp }}/ContractDerivedData
    steps:
      - name: Checkout
        uses: actions/checkout@v6

      - name: Enforce macOS 26 ARM runner
        shell: bash
        run: |
          set -euo pipefail
          [[ "$(sw_vers -productVersion)" == 26.* ]]
          [[ "$(uname -m)" == arm64 ]]

      - name: Capture project contract
        shell: bash
        run: bash scripts/capture-xcodeproj-contract.sh

      - name: Verify capture is read-only
        shell: bash
        run: git diff --exit-code

      - name: Upload project contract
        if: always()
        uses: actions/upload-artifact@v7
        with:
          name: xcodeproj-contract-${{ github.run_id }}-${{ github.run_attempt }}
          path: ${{ runner.temp }}/xcodeproj-contract
          if-no-files-found: error
          retention-days: 30
```

- [ ] **Step 2: Commit the workflow**

```bash
git add .github/workflows/xcodeproj-contract.yml
git commit -m "ci(xcodegen-m0): upload Xcode project contract"
```

- [ ] **Step 3: Push and dispatch M0 on the branch**

Run:

```bash
git push -u origin xcodegen-m0-contract
gh workflow run "Capture Xcode Project Contract" --ref xcodegen-m0-contract
```

Expected: one run starts on `macos-26`; do not dispatch a second run concurrently.

- [ ] **Step 4: Verify the runner result and artifact**

Run:

```bash
run_id=$(gh run list --workflow "Capture Xcode Project Contract" --branch xcodegen-m0-contract \
  --limit 1 --json databaseId -q '.[0].databaseId')
gh run view "$run_id" --json status,conclusion,jobs
gh run download "$run_id" -n "xcodeproj-contract-$run_id-1" \
  -D /tmp/maccy-xcodeproj-contract
```

Expected:

- workflow conclusion `success`;
- `git-status-before.txt` and `git-status-after.txt` empty;
- three targets in `project-list.json`;
- six build-setting JSON files;
- app bundle and localization inventories present;
- scheme, test plan, package lock, pbxproj JSON, build log, and checksums present.

- [ ] **Step 5: Record M0 evidence before M1**

Append the run URL and artifact inventory to `docs/audit/2026-07-10-xcodeproj-generation-research.md`. Do not begin `project.yml` until the artifact proves the legacy contract is captured.
