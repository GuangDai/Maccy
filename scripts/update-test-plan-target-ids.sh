#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
PROJECT_NAME="${PROJECT_NAME:-Maccy}"
PROJECT="${PROJECT:-$PROJECT_ROOT/$PROJECT_NAME.xcodeproj}"
TEST_PLAN="${TEST_PLAN:-$PROJECT_ROOT/Maccy.xctestplan}"

test -f "$PROJECT/project.pbxproj"
test -f "$TEST_PLAN"

project_json="$(mktemp)"
updated_plan="$(mktemp)"
trap 'rm -f "$project_json" "$updated_plan"' EXIT
plutil -convert json -o "$project_json" "$PROJECT/project.pbxproj"

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
container_path="container:$(basename "$PROJECT")"

jq -e '
  .version == 1
  and any(
    .defaultOptions.commandLineArgumentEntries[]?;
    .argument == "enable-testing"
  )
  and ([.testTargets[]?.target.name] | sort == ["MaccyTests", "MaccyUITests"])
' "$TEST_PLAN" >/dev/null

jq \
  --arg app_id "$app_id" \
  --arg unit_id "$unit_id" \
  --arg ui_id "$ui_id" \
  --arg container_path "$container_path" '
    .defaultOptions.targetForVariableExpansion.containerPath = $container_path
    | .defaultOptions.targetForVariableExpansion.identifier = $app_id
    | (
        .testTargets[]
        | select(.target.name == "MaccyTests")
        | .target.containerPath
      ) = $container_path
    | (
        .testTargets[]
        | select(.target.name == "MaccyTests")
        | .target.identifier
      ) = $unit_id
    | (
        .testTargets[]
        | select(.target.name == "MaccyUITests")
        | .target.containerPath
      ) = $container_path
    | (
        .testTargets[]
        | select(.target.name == "MaccyUITests")
        | .target.identifier
      ) = $ui_id
  ' "$TEST_PLAN" > "$updated_plan"

mv "$updated_plan" "$TEST_PLAN"

printf 'Updated %s target identifiers\n' "$TEST_PLAN"
printf 'Maccy %s\n' "$app_id"
printf 'MaccyTests %s\n' "$unit_id"
printf 'MaccyUITests %s\n' "$ui_id"
