# Release Compiler Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the effective Release compiler settings on the macOS runner and add C/C++ O2 only if the resolved default is lower.

**Architecture:** A repository script reads `xcodebuild -showBuildSettings` for the Maccy Release target and enforces C/C++ O2-or-higher plus Swift `-O` whole-module compilation. The dry-run release workflow executes this gate before building the distributable app; the xcconfig changes only when the runner proves an override is needed.

**Tech Stack:** Bash, Xcode build settings, GitHub Actions, XcodeGen xcconfig references.

## Global Constraints

- Do not run Xcode, Swift tests, or SwiftLint locally; this host has no macOS toolchain.
- Do not add `-Ounchecked`, `-Ofast`, fast-math, strict-aliasing overrides, or undocumented Swift frontend flags.
- If effective `GCC_OPTIMIZATION_LEVEL` is `2` or `3`, do not add a redundant override.
- Keep Debug and test configuration behavior unchanged.
- Run only one GitHub workflow at a time and sleep 90 seconds before every status recheck.

---

### Task 1: Effective Release optimization gate

**Files:**
- Create: `scripts/verify-release-optimizations.sh`
- Modify: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `PROJECT`, `TARGET`, and `CONFIGURATION` environment variables, with Maccy/Release defaults.
- Produces: a nonzero exit when Clang is below O2, Swift is not `-O`, or Swift is not whole-module; prints resolved values for diagnosis.

- [ ] **Step 1: Add the runner-side verifier**

```bash
#!/usr/bin/env bash
set -euo pipefail

PROJECT="${PROJECT:-Maccy.xcodeproj}"
TARGET="${TARGET:-Maccy}"
CONFIGURATION="${CONFIGURATION:-Release}"

settings="$(xcodebuild -project "$PROJECT" -target "$TARGET" -configuration "$CONFIGURATION" -showBuildSettings)"

setting() {
  awk -v key="$1" '$1 == key && $2 == "=" {
    $1 = ""; $2 = ""; sub(/^[[:space:]]+/, ""); print; exit
  }' <<<"$settings"
}

clang_level="$(setting GCC_OPTIMIZATION_LEVEL)"
swift_level="$(setting SWIFT_OPTIMIZATION_LEVEL)"
swift_mode="$(setting SWIFT_COMPILATION_MODE)"
lto_mode="$(setting LLVM_LTO)"

echo "GCC_OPTIMIZATION_LEVEL=$clang_level"
echo "SWIFT_OPTIMIZATION_LEVEL=$swift_level"
echo "SWIFT_COMPILATION_MODE=$swift_mode"
echo "LLVM_LTO=$lto_mode"

case "$clang_level" in
  2|3) ;;
  *) echo "Release C/C++ optimization must resolve to O2 or higher" >&2; exit 1 ;;
esac
[[ "$swift_level" == "-O" ]] || {
  echo "Release Swift optimization must resolve to -O" >&2
  exit 1
}
[[ "$swift_mode" == "wholemodule" ]] || {
  echo "Release Swift compilation must resolve to wholemodule" >&2
  exit 1
}
```

- [ ] **Step 2: Wire the verifier before packaging**

Insert this step after project regeneration verification in `.github/workflows/release.yml`:

```yaml
      - name: Verify effective Release optimizations
        shell: bash
        env:
          TARGET: Maccy
        run: bash scripts/verify-release-optimizations.sh
```

- [ ] **Step 3: Check shell syntax and commit**

Run: `bash -n scripts/verify-release-optimizations.sh`

Expected: exit 0 with no output.

```bash
git add scripts/verify-release-optimizations.sh .github/workflows/release.yml
git commit -m "ci(release): verify effective compiler optimization"
```

- [ ] **Step 4: Run the non-publishing Release workflow**

```bash
git push origin quality-search-corpus-projection
gh workflow run "Package and Release macOS App" --ref quality-search-corpus-projection -f publish=false -f prerelease=false
gh run list --workflow "Package and Release macOS App" --limit 3
```

Before each `gh run view` status recheck, run `sleep 90`.

Expected outcome A: success and log values `GCC_OPTIMIZATION_LEVEL=2` or `3`, `SWIFT_OPTIMIZATION_LEVEL=-O`, `SWIFT_COMPILATION_MODE=wholemodule`; do not modify xcconfig.

Expected outcome B: the verifier fails and prints a lower C/C++ level; continue to Task 2.

### Task 2: Conditional C/C++ O2 override

**Files:**
- Modify only if Task 1 reports C/C++ below O2: `Config/Project-Release.xcconfig`

**Interfaces:**
- Consumes: the exact lower `GCC_OPTIMIZATION_LEVEL` printed by Task 1.
- Produces: an effective Release C/C++ level of `2` without changing Swift or Debug settings.

- [ ] **Step 1: Add the minimum required override only after a failing runner result**

```xcconfig
GCC_OPTIMIZATION_LEVEL = 2
```

Place it after `ENABLE_NS_ASSERTIONS = NO` in `Config/Project-Release.xcconfig`.

- [ ] **Step 2: Commit the proven correction**

```bash
git add Config/Project-Release.xcconfig
git commit -m "build(release): enable C++ O2"
```

- [ ] **Step 3: Re-run the dry-run Release workflow**

Push the branch, dispatch `Package and Release macOS App` with `publish=false`, and poll at 90-second intervals.

Expected: verifier passes, Release build links, package-log scan passes, and a non-published `Maccy.app.zip` artifact is uploaded.
