#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
PROJECT_NAME="${PROJECT_NAME:-Maccy}"
PROJECT="$PROJECT_ROOT/$PROJECT_NAME.xcodeproj"
TEST_PLAN="$PROJECT_ROOT/Maccy.xctestplan"

temporary_root="$(mktemp -d)"
EVIDENCE_DIR="${EVIDENCE_DIR:-$temporary_root/evidence}"
trap 'rm -rf "$temporary_root"' EXIT
mkdir -p "$EVIDENCE_DIR"

PROJECT_ROOT="$PROJECT_ROOT" PROJECT_NAME="$PROJECT_NAME" \
  bash "$PROJECT_ROOT/scripts/regenerate-xcodeproj.sh" \
  2>&1 | tee "$EVIDENCE_DIR/generate-first.log"

cp -R "$PROJECT" "$temporary_root/first-generated.xcodeproj"
cp "$TEST_PLAN" "$temporary_root/first-generated.xctestplan"

PROJECT_ROOT="$PROJECT_ROOT" PROJECT_NAME="$PROJECT_NAME" \
  bash "$PROJECT_ROOT/scripts/regenerate-xcodeproj.sh" \
  2>&1 | tee "$EVIDENCE_DIR/generate-second.log"

diff -ru \
  "$temporary_root/first-generated.xcodeproj" \
  "$PROJECT" \
  | tee "$EVIDENCE_DIR/repeatability.diff"
diff -u \
  "$temporary_root/first-generated.xctestplan" \
  "$TEST_PLAN" \
  | tee "$EVIDENCE_DIR/test-plan-repeatability.diff"

git -C "$PROJECT_ROOT" diff --exit-code -- \
  "$PROJECT_NAME.xcodeproj" \
  Maccy.xctestplan \
  "$PROJECT_NAME.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
  | tee "$EVIDENCE_DIR/committed-output.diff"

echo "Xcode project generation is repeatable and committed output is current"
