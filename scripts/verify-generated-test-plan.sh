#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
GENERATED_PROJECT="${GENERATED_PROJECT:-$PROJECT_ROOT/Maccy-Generated.xcodeproj}"
GENERATED_TEST_PLAN="${GENERATED_TEST_PLAN:-$PROJECT_ROOT/Maccy-Generated.xctestplan}"
GENERATED_SCHEME="${GENERATED_SCHEME:-$GENERATED_PROJECT/xcshareddata/xcschemes/Maccy.xcscheme}"

test -f "$GENERATED_PROJECT/project.pbxproj"
test -f "$GENERATED_TEST_PLAN"
test -f "$GENERATED_SCHEME"

project_json="$(mktemp)"
trap 'rm -f "$project_json"' EXIT
plutil -convert json -o "$project_json" "$GENERATED_PROJECT/project.pbxproj"

target_id() {
  local target_name="$1"
  jq -er --arg target_name "$target_name" '
    [
      .objects
      | to_entries[]
      | select(.value.isa == "PBXNativeTarget" and .value.name == $target_name)
      | .key
    ]
    | if length == 1 then .[0] else error("expected exactly one target named " + $target_name) end
  ' "$project_json"
}

app_id="$(target_id Maccy)"
unit_id="$(target_id MaccyTests)"
ui_id="$(target_id MaccyUITests)"
container_path="container:$(basename "$GENERATED_PROJECT")"

jq -e \
  --arg app_id "$app_id" \
  --arg unit_id "$unit_id" \
  --arg ui_id "$ui_id" \
  --arg container_path "$container_path" '
    .version == 1
    and any(
      .defaultOptions.commandLineArgumentEntries[]?;
      .argument == "enable-testing"
    )
    and (
      .defaultOptions.targetForVariableExpansion
      == {
        containerPath: $container_path,
        identifier: $app_id,
        name: "Maccy"
      }
    )
    and (.testTargets | length == 2)
    and any(
      .testTargets[]?.target;
      .containerPath == $container_path
      and .identifier == $unit_id
      and .name == "MaccyTests"
    )
    and any(
      .testTargets[]?.target;
      .containerPath == $container_path
      and .identifier == $ui_id
      and .name == "MaccyUITests"
    )
  ' "$GENERATED_TEST_PLAN" >/dev/null

grep -Fq 'reference = "container:Maccy-Generated.xctestplan"' "$GENERATED_SCHEME"
grep -Fq 'default = "YES"' "$GENERATED_SCHEME"
grep -Fq "BlueprintIdentifier = \"$app_id\"" "$GENERATED_SCHEME"
grep -Fq "BlueprintIdentifier = \"$unit_id\"" "$GENERATED_SCHEME"
grep -Fq "BlueprintIdentifier = \"$ui_id\"" "$GENERATED_SCHEME"

printf 'Generated test plan verified\n'
printf 'Maccy %s\n' "$app_id"
printf 'MaccyTests %s\n' "$unit_id"
printf 'MaccyUITests %s\n' "$ui_id"
