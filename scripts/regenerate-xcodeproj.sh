#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
PROJECT_NAME="${PROJECT_NAME:-Maccy}"
PROJECT="$PROJECT_ROOT/$PROJECT_NAME.xcodeproj"
PACKAGE_LOCK="$PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
TEST_PLAN="$PROJECT_ROOT/Maccy.xctestplan"

test -f "$PACKAGE_LOCK"
test -f "$TEST_PLAN"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
cp "$PACKAGE_LOCK" "$temporary_root/Package.resolved"

PROJECT_ROOT="$PROJECT_ROOT" \
OUTPUT_ROOT="$PROJECT_ROOT" \
PROJECT_NAME="$PROJECT_NAME" \
  bash "$PROJECT_ROOT/scripts/generate-xcodeproj.sh"

mkdir -p "$(dirname "$PACKAGE_LOCK")"
cp "$temporary_root/Package.resolved" "$PACKAGE_LOCK"

PROJECT_ROOT="$PROJECT_ROOT" \
PROJECT_NAME="$PROJECT_NAME" \
PROJECT="$PROJECT" \
TEST_PLAN="$TEST_PLAN" \
  bash "$PROJECT_ROOT/scripts/update-test-plan-target-ids.sh"

PROJECT_ROOT="$PROJECT_ROOT" \
GENERATED_PROJECT="$PROJECT" \
GENERATED_TEST_PLAN="$TEST_PLAN" \
  bash "$PROJECT_ROOT/scripts/verify-generated-test-plan.sh"

echo "Regenerated $PROJECT"
echo "Preserved $PACKAGE_LOCK"
