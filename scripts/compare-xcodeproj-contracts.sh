#!/usr/bin/env bash
set -euo pipefail

LEGACY_PROJECT="${LEGACY_PROJECT:-$PWD/Maccy.xcodeproj}"
GENERATED_PROJECT="${GENERATED_PROJECT:?GENERATED_PROJECT is required}"
OUTPUT_DIR="${OUTPUT_DIR:?OUTPUT_DIR is required}"

mkdir -p "$OUTPUT_DIR"

legacy_json="$OUTPUT_DIR/legacy-project.json"
generated_json="$OUTPUT_DIR/generated-project.json"
legacy_graph="$OUTPUT_DIR/legacy-graph.json"
generated_graph="$OUTPUT_DIR/generated-graph.json"

plutil -convert json -o "$legacy_json" "$LEGACY_PROJECT/project.pbxproj"
plutil -convert json -o "$generated_json" "$GENERATED_PROJECT/project.pbxproj"

normalize_graph() {
  local input="$1"
  local output="$2"

  jq --sort-keys '
    .objects as $objects
    | def basename:
        if type == "string" then split("/") | last else . end;
      def build_file_name($build_id):
        $objects[$build_id] as $build
        | if $build.fileRef then
            ($objects[$build.fileRef].path
              // $objects[$build.fileRef].name
              // $build.name
              // $build.fileRef)
            | basename
          elif $build.productRef then
            ($objects[$build.productRef].productName
              // $objects[$build.productRef].name
              // $build.productRef)
            | basename
          else
            ($build.name // $build_id) | basename
          end;
      def phase_files($phase):
        [$phase.files[]? | build_file_name(.)] | sort;
      {
        project: (
          $objects
          | to_entries[]
          | select(.value.isa == "PBXProject")
          | {
              knownRegions: (.value.knownRegions | sort),
              targetCount: (.value.targets | length)
            }
        ),
        targets: [
          $objects
          | to_entries[]
          | select(.value.isa == "PBXNativeTarget")
          | .value as $target
          | {
              name: $target.name,
              productType: $target.productType,
              dependencies: (
                [
                  $target.dependencies[]?
                  | $objects[.].target as $target_id
                  | $objects[$target_id].name
                ]
                | sort
              ),
              phases: (
                [
                  $target.buildPhases[]?
                  | $objects[.] as $phase
                  | select(
                      $phase.isa == "PBXSourcesBuildPhase"
                      or $phase.isa == "PBXResourcesBuildPhase"
                      or $phase.isa == "PBXFrameworksBuildPhase"
                    )
                  | {
                      kind: $phase.isa,
                      files: phase_files($phase)
                    }
                ]
                | sort_by(.kind)
              )
            }
        ] | sort_by(.name),
        packages: [
          $objects
          | to_entries[]
          | select(.value.isa == "XCRemoteSwiftPackageReference")
          | {
              url: .value.repositoryURL,
              requirement: .value.requirement
            }
        ] | sort_by(.url)
      }
  ' "$input" > "$output"
}

normalize_graph "$legacy_json" "$legacy_graph"
normalize_graph "$generated_json" "$generated_graph"

failed=0
graph_diff="$OUTPUT_DIR/project-graph.diff"
if ! diff -u "$legacy_graph" "$generated_graph" > "$graph_diff"; then
  cat "$graph_diff"
  failed=1
fi

setting_keys='[
  "ALWAYS_SEARCH_USER_PATHS",
  "ARCHS",
  "ASSETCATALOG_COMPILER_APPICON_NAME",
  "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS",
  "BUNDLE_LOADER",
  "CLANG_ANALYZER_LOCALIZABILITY_NONLOCALIZED",
  "CLANG_ANALYZER_NONNULL",
  "CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION",
  "CLANG_CXX_LANGUAGE_STANDARD",
  "CLANG_CXX_LIBRARY",
  "CLANG_ENABLE_MODULES",
  "CLANG_ENABLE_OBJC_ARC",
  "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING",
  "CLANG_WARN_BOOL_CONVERSION",
  "CLANG_WARN_COMMA",
  "CLANG_WARN_CONSTANT_CONVERSION",
  "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS",
  "CLANG_WARN_DIRECT_OBJC_ISA_USAGE",
  "CLANG_WARN_DOCUMENTATION_COMMENTS",
  "CLANG_WARN_EMPTY_BODY",
  "CLANG_WARN_ENUM_CONVERSION",
  "CLANG_WARN_INFINITE_RECURSION",
  "CLANG_WARN_INT_CONVERSION",
  "CLANG_WARN_NON_LITERAL_NULL_CONVERSION",
  "CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF",
  "CLANG_WARN_OBJC_LITERAL_CONVERSION",
  "CLANG_WARN_OBJC_ROOT_CLASS",
  "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER",
  "CLANG_WARN_RANGE_LOOP_ANALYSIS",
  "CLANG_WARN_STRICT_PROTOTYPES",
  "CLANG_WARN_SUSPICIOUS_MOVE",
  "CLANG_WARN_UNGUARDED_AVAILABILITY",
  "CLANG_WARN_UNREACHABLE_CODE",
  "CLANG_WARN__DUPLICATE_METHOD_MATCH",
  "CODE_SIGN_ENTITLEMENTS",
  "CODE_SIGN_IDENTITY",
  "CODE_SIGN_STYLE",
  "COMBINE_HIDPI_IMAGES",
  "COPY_PHASE_STRIP",
  "CURRENT_PROJECT_VERSION",
  "DEAD_CODE_STRIPPING",
  "DEBUG_INFORMATION_FORMAT",
  "DEVELOPMENT_TEAM",
  "ENABLE_HARDENED_RUNTIME",
  "ENABLE_NS_ASSERTIONS",
  "ENABLE_STRICT_OBJC_MSGSEND",
  "ENABLE_TESTABILITY",
  "ENABLE_USER_SCRIPT_SANDBOXING",
  "FRAMEWORK_SEARCH_PATHS",
  "GCC_C_LANGUAGE_STANDARD",
  "GCC_DYNAMIC_NO_PIC",
  "GCC_NO_COMMON_BLOCKS",
  "GCC_OPTIMIZATION_LEVEL",
  "GCC_PREPROCESSOR_DEFINITIONS",
  "GCC_WARN_64_TO_32_BIT_CONVERSION",
  "GCC_WARN_ABOUT_RETURN_TYPE",
  "GCC_WARN_UNDECLARED_SELECTOR",
  "GCC_WARN_UNINITIALIZED_AUTOS",
  "GCC_WARN_UNUSED_FUNCTION",
  "GCC_WARN_UNUSED_VARIABLE",
  "INFOPLIST_FILE",
  "INFOPLIST_KEY_LSApplicationCategoryType",
  "LD_RUNPATH_SEARCH_PATHS",
  "MACOSX_DEPLOYMENT_TARGET",
  "MARKETING_VERSION",
  "MTL_ENABLE_DEBUG_INFO",
  "ONLY_ACTIVE_ARCH",
  "PRODUCT_BUNDLE_IDENTIFIER",
  "PRODUCT_NAME",
  "PROVISIONING_PROFILE_SPECIFIER",
  "SDKROOT",
  "SWIFT_ACTIVE_COMPILATION_CONDITIONS",
  "SWIFT_COMPILATION_MODE",
  "SWIFT_OBJC_BRIDGING_HEADER",
  "SWIFT_OPTIMIZATION_LEVEL",
  "SWIFT_STRICT_CONCURRENCY",
  "SWIFT_SWIFT3_OBJC_INFERENCE",
  "SWIFT_VERSION",
  "TEST_HOST",
  "TEST_TARGET_NAME"
]'

normalize_settings() {
  local input="$1"
  local project_dir="$2"
  local output="$3"

  jq \
    --argjson keys "$setting_keys" \
    --arg project_dir "$project_dir" \
    --sort-keys '
      .[0].buildSettings
      | with_entries(select(.key as $key | $keys | index($key)))
      | walk(
          if type == "string" then
            gsub($project_dir; "<PROJECT_DIR>")
          else
            .
          end
        )
    ' "$input" > "$output"
}

legacy_dir="$(cd "$(dirname "$LEGACY_PROJECT")" && pwd)"
generated_dir="$(cd "$(dirname "$GENERATED_PROJECT")" && pwd)"

for configuration in Debug Release; do
  for target in Maccy MaccyTests MaccyUITests; do
    stem="$target-$configuration"
    legacy_raw="$OUTPUT_DIR/legacy-settings-$stem.raw.json"
    generated_raw="$OUTPUT_DIR/generated-settings-$stem.raw.json"
    legacy_normalized="$OUTPUT_DIR/legacy-settings-$stem.json"
    generated_normalized="$OUTPUT_DIR/generated-settings-$stem.json"
    settings_diff="$OUTPUT_DIR/settings-$stem.diff"

    xcodebuild \
      -project "$LEGACY_PROJECT" \
      -target "$target" \
      -configuration "$configuration" \
      -showBuildSettings \
      -json \
      CODE_SIGNING_ALLOWED=NO \
      > "$legacy_raw"

    xcodebuild \
      -project "$GENERATED_PROJECT" \
      -target "$target" \
      -configuration "$configuration" \
      -showBuildSettings \
      -json \
      CODE_SIGNING_ALLOWED=NO \
      > "$generated_raw"

    normalize_settings "$legacy_raw" "$legacy_dir" "$legacy_normalized"
    normalize_settings "$generated_raw" "$generated_dir" "$generated_normalized"

    if ! diff -u "$legacy_normalized" "$generated_normalized" > "$settings_diff"; then
      cat "$settings_diff"
      failed=1
    fi
  done
done

exit "$failed"
