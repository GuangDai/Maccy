#!/usr/bin/env bash
set -euo pipefail

PROJECT="${PROJECT:-Maccy.xcodeproj}"
TARGET="${TARGET:-Maccy}"
CONFIGURATION="${CONFIGURATION:-Release}"

settings="$(
  xcodebuild \
    -project "$PROJECT" \
    -target "$TARGET" \
    -configuration "$CONFIGURATION" \
    -showBuildSettings
)"

setting() {
  awk -v key="$1" '$1 == key && $2 == "=" {
    $1 = ""
    $2 = ""
    sub(/^[[:space:]]+/, "")
    print
    exit
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
  2 | 3) ;;
  *)
    echo "Release C/C++ optimization must resolve to O2 or higher" >&2
    exit 1
    ;;
esac

if [[ "$swift_level" != "-O" ]]; then
  echo "Release Swift optimization must resolve to -O" >&2
  exit 1
fi

if [[ "$swift_mode" != "wholemodule" ]]; then
  echo "Release Swift compilation must resolve to wholemodule" >&2
  exit 1
fi
