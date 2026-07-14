# Release Compiler Optimization Design

## Goal

Make Release compiler optimization explicit and as aggressive as practical
without changing Swift safety semantics, C/C++ floating-point semantics, Debug
behavior, or test diagnosability.

## Current state

`Project-Release.xcconfig` already sets Swift to `-O` with whole-module
compilation. That is Swift's highest normal speed-optimization mode while
retaining preconditions and safety checks. Because XcodeGen setting presets are
disabled, the project does not explicitly set a Release C/C++ optimization
level or link-time optimization.

## Selection rule

Treat the macOS runner's resolved Release settings as the source of truth before
adding an override:

- if `GCC_OPTIMIZATION_LEVEL` resolves to `2` or `3`, leave C/C++ untouched;
- if it resolves below `2` (including `0`, `1`, or a size-oriented level), add
  `GCC_OPTIMIZATION_LEVEL = 2` to `Project-Release.xcconfig`;
- retain `SWIFT_OPTIMIZATION_LEVEL = -O`;
- retain `SWIFT_COMPILATION_MODE = wholemodule`.

Do not enable LTO without measured benefit. Maccy's C++ layer has only
`ClipboardByteProcessor.cpp` and the Objective-C++ bridge translation unit;
Swift calls through the Objective-C runtime boundary, which LTO cannot erase.
The likely gain does not justify adding Release link cost without a benchmark.

Do not add Swift `-Ounchecked`, `GCC_FAST_MATH`, `-Ofast`, strict-aliasing
overrides, unchecked arithmetic, or undocumented Swift frontend flags. Those
options can change observable behavior or memory-safety assumptions and are not
valid compiler-only optimizations for this app.

Debug xcconfigs and the Debug test workflow remain unchanged. Release tests are
not introduced: the existing suite relies on `enable-testing` and Debug-only
test gates, while the package workflow is the authoritative Release compile and
link check.

## Source of truth and generated project

Any required setting lives only in `Config/Project-Release.xcconfig`;
`project.yml` keeps referencing that configuration. If the effective default is
already O2 or higher, no redundant compiler setting is added. The checked-in
`Maccy.xcodeproj` remains generated and parity-checked as usual. No per-file
optimization flags are added.

## Verification

Add a small shell probe that asks `xcodebuild -showBuildSettings` for the Maccy
Release target and records the effective C/C++ and Swift settings. Use its first
runner result to apply the selection rule above. Keep a package-workflow check
for the resulting minimum (`GCC_OPTIMIZATION_LEVEL >= 2`, Swift `-O`, Swift
whole-module) so a later toolchain/project change cannot silently disable
Release optimization.

After the ordinary full Debug CI is green, run `Package and Release macOS App`
manually with `publish=false` on the feature branch. Success proves the Release
configuration compiles, the setting assertions match the actual Xcode build,
and the resulting zip still contains only `Maccy.app` and its runtime resources.
