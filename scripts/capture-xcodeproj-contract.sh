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
