#!/usr/bin/env bash
set -euo pipefail

readonly XCODEGEN_VERSION="2.45.4"
readonly XCODEGEN_URL="https://github.com/yonaskolb/XcodeGen/releases/download/2.45.4/xcodegen.zip"
readonly XCODEGEN_SHA256="090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef"

PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
SPEC="${SPEC:-$PROJECT_ROOT/project.yml}"
TEMP_ROOT="${TMPDIR:-/tmp}"
OUTPUT_ROOT="${OUTPUT_ROOT:-$TEMP_ROOT/MaccyGeneratedProject}"
XCODEGEN_HOME="${XCODEGEN_HOME:-$TEMP_ROOT/xcodegen-$XCODEGEN_VERSION}"

archive="$XCODEGEN_HOME/xcodegen.zip"
binary="$XCODEGEN_HOME/xcodegen/bin/xcodegen"
generated_project="$OUTPUT_ROOT/Maccy-Generated.xcodeproj/project.pbxproj"

test -f "$SPEC"
mkdir -p "$XCODEGEN_HOME" "$OUTPUT_ROOT"

if [[ ! -f "$archive" ]]; then
  curl \
    --fail \
    --location \
    --proto '=https' \
    --retry 3 \
    --show-error \
    --silent \
    --tlsv1.2 \
    "$XCODEGEN_URL" \
    --output "$archive"
fi

actual_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
if [[ "$actual_sha256" != "$XCODEGEN_SHA256" ]]; then
  echo "XcodeGen archive checksum mismatch" >&2
  echo "Expected: $XCODEGEN_SHA256" >&2
  echo "Actual:   $actual_sha256" >&2
  exit 1
fi

if [[ ! -x "$binary" ]]; then
  unzip -q -o "$archive" -d "$XCODEGEN_HOME"
fi

actual_version="$($binary --version)"
if [[ "$actual_version" != "$XCODEGEN_VERSION" ]]; then
  echo "XcodeGen version mismatch" >&2
  echo "Expected: $XCODEGEN_VERSION" >&2
  echo "Actual:   $actual_version" >&2
  exit 1
fi

"$binary" generate \
  --spec "$SPEC" \
  --project-root "$PROJECT_ROOT" \
  --project "$OUTPUT_ROOT"

test -f "$generated_project"

echo "XcodeGen $actual_version"
echo "SHA-256 $actual_sha256"
echo "Generated $generated_project"
