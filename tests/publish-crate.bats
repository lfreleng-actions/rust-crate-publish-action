#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Overture Maps
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Unit tests for scripts/publish-crate.sh, run against cargo, rustup and
# curl stand-ins (fixtures/). No network access, compilation or
# publishing.

# Each @test runs in its own subshell and setup() resets the state, so
# variables exported inside one test are meant to stay local to it.
# shellcheck disable=SC2030,SC2031

bats_require_minimum_version 1.7.0

setup() {
  repo_dir="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  action_file="$repo_dir/action.yaml"
  script="$repo_dir/scripts/publish-crate.sh"
  mkdir -p "$BATS_TEST_TMPDIR/work space"
  workdir="$(cd "$BATS_TEST_TMPDIR/work space" && pwd -P)"
  project="$workdir/member crate"
  mkdir -p "$workdir/bin" "$project" "$workdir/cargo home" \
    "$workdir/runner temp"
  local tool
  for tool in cargo rustup curl; do
    cp "$BATS_TEST_DIRNAME/fixtures/$tool.sh" "$workdir/bin/$tool"
    chmod +x "$workdir/bin/$tool"
  done
  cp "$BATS_TEST_DIRNAME/fixtures/Cargo.toml" "$project/Cargo.toml"

  export PATH="$workdir/bin:$PATH"
  export GITHUB_WORKSPACE="$workdir"
  export GITHUB_OUTPUT="$workdir/github output"
  export GITHUB_STEP_SUMMARY="$workdir/job summary"
  export RUNNER_TEMP="$workdir/runner temp"
  export CARGO_HOME="$workdir/cargo home"
  export INPUT_PATH_PREFIX="member crate"
  export MOCK_EXPECT_MANIFEST="$project/Cargo.toml"
  export MOCK_CARGO_LOG="$workdir/cargo calls"
  export MOCK_CARGO_ENV="$workdir/cargo env"
  export MOCK_CARGO_TARGETS="$workdir/cargo targets"
  export MOCK_CARGO_VARS="$workdir/cargo vars"
  export MOCK_CARGO_SETS="$workdir/cargo sets"
  export MOCK_RUSTUP_LOG="$workdir/rustup calls"
  export MOCK_RUSTUP_VARS="$workdir/rustup vars"
  export MOCK_CURL_LOG="$workdir/curl calls"
  export MOCK_MANIFEST_JSON="$workdir/manifest.json"
  cp "$BATS_TEST_DIRNAME/fixtures/manifest.json" "$MOCK_MANIFEST_JSON"
  export MOCK_CRATE_SIZE=32
  unset INPUT_MANIFEST_PATH INPUT_RELEASE_TAG INPUT_MAX_CRATE_SIZE_BYTES
  unset INPUT_DRY_RUN INPUT_PERMIT_FAIL INPUT_SUMMARY INPUT_REGISTRY_TOKEN
  unset INPUT_EXPECTED_SHA256
  unset MOCK_FAIL_STAGE MOCK_MISSING_PACKAGE MOCK_TAMPER MOCK_TOOLCHAIN
  unset MOCK_INCLUDE_OTHER_PACKAGE MOCK_CARGO_WARNING MOCK_CARGO_VERSION
  unset MOCK_RUSTUP_FAIL MOCK_CURL_FAIL MOCK_INDEX_STATUS MOCK_INDEX_BODY
  unset MOCK_INDEX_STATUS_2 MOCK_INDEX_BODY_2 CARGO_TARGET_DIR
  unset ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL
  unset ACTIONS_RUNTIME_TOKEN GITHUB_ENV GITHUB_PATH GITHUB_STATE
  unset INPUT_REGISTRY MOCK_EXPECT_REGISTRY MOCK_CONFIG_STATUS
  unset MOCK_CONFIG_BODY MOCK_DRY_RUN_EXISTS
  unset GITHUB_REPOSITORY GITHUB_WORKFLOW_REF RUSTUP_TOOLCHAIN
  unset INPUT_WORKSPACE INPUT_PACKAGES INPUT_EXCLUDE MOCK_WORKSPACE_JSON
  unset MOCK_EXPECT_PACKAGE_MANIFEST MOCK_INDEX_DIR MOCK_PUBLISH_FAIL_AT
  unset MOCK_RACE_CKSUM MOCK_INDEX_DIR_MISSING
  # Host registry settings would reach the stand-ins and break the exact
  # scrub assertions.
  local name
  for name in $(compgen -e); do
    case "$name" in
      CARGO_REGISTRY_* | CARGO_REGISTRIES_*) unset "$name" ;;
    esac
  done
  local file
  for file in "$GITHUB_OUTPUT" "$GITHUB_STEP_SUMMARY" "$MOCK_CARGO_LOG" \
    "$MOCK_CARGO_ENV" "$MOCK_CARGO_TARGETS" "$MOCK_RUSTUP_LOG" \
    "$MOCK_CURL_LOG" "$MOCK_CARGO_VARS" "$MOCK_RUSTUP_VARS" \
    "$MOCK_CARGO_SETS"; do
    : > "$file"
  done
}

run_action() {
  : > "$MOCK_CURL_LOG"
  run "$BASH" "$script"
}

assert_calls() {
  [ "$(cat "$MOCK_CARGO_LOG")" = "$1" ]
}

assert_no_cargo() {
  [ ! -s "$MOCK_CARGO_LOG" ]
}

reset_logs() {
  : > "$MOCK_CARGO_LOG"
  : > "$MOCK_CARGO_ENV"
  : > "$MOCK_CARGO_SETS"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_STEP_SUMMARY"
}

# Field N (1-based) of the recorded environment for a cargo stage:
# 2 cwd, 3 CARGO_REGISTRY_TOKEN, 4 CARGO_REGISTRIES_CRATES_IO_TOKEN,
# 5 ACTIONS_ID_TOKEN_REQUEST_TOKEN, 6 INPUT_REGISTRY_TOKEN,
# 7 CARGO_REGISTRY_CREDENTIAL_PROVIDER, 8 RUSTUP_TOOLCHAIN.
stage_env() {
  awk -F'|' -v stage="$1" -v field="$2" \
    '$1 == stage { print $field }' "$MOCK_CARGO_ENV"
}

# The scrub-relevant NAME=value pairs a cargo stage could see, sorted
# and space-separated.
stage_vars() {
  sed -n "s/^$1|//p" "$MOCK_CARGO_VARS"
}

output_value() {
  sed -n "s/^$1=//p" "$GITHUB_OUTPUT"
}

# SHA-256 of N zero bytes, the content the cargo stand-in packages.
zero_sha256() {
  if command -v sha256sum > /dev/null 2>&1; then
    head -c "$1" /dev/zero | sha256sum | cut -d' ' -f1
  else
    head -c "$1" /dev/zero | shasum -a 256 | cut -d' ' -f1
  fi
}

# Serve a crates.io index entry for VERSION with CKSUM.
index_entry() {
  printf '{"name":"example-crate","vers":"%s","cksum":"%s","yanked":%s}\n' \
    "$1" "$2" "${3:-false}" > "$workdir/index.json"
  export MOCK_INDEX_STATUS=200 MOCK_INDEX_BODY="$workdir/index.json"
}

readonly publish_calls=$'version\nmetadata\npackage\ndry-run\nrepackage\npublish'
readonly dry_run_calls=$'version\nmetadata\npackage\ndry-run\nrepackage'

# Describe a workspace below the project directory to the cargo
# stand-in. Each argument is NAME:VERSION:DEPS:PUBLISH. DEPS is a comma
# list of members, each optionally suffixed '@build', '@dev' (without a
# version, as Cargo strips on publishing), '@devv' (versioned dev),
# '@ext' (a registry crate of that name, not the member) or '@out' (a
# path crate of that name outside the workspace). PUBLISH is
# empty (any registry), 'false', or a comma list of registries.
make_workspace() {
  local spec name version deps publish entries="[]"
  export MOCK_WORKSPACE_JSON="$workdir/workspace.json"
  export MOCK_INDEX_DIR="$workdir/index"
  mkdir -p "$MOCK_INDEX_DIR"
  for spec in "$@"; do
    IFS=: read -r name version deps publish <<< "$spec"
    mkdir -p "$project/crates/$name"
    : > "$project/crates/$name/Cargo.toml"
    entries="$(jq -c --arg n "$name" --arg v "$version" \
      --arg m "$project/crates/$name/Cargo.toml" --arg deps "$deps" \
      --arg pub "$publish" --arg root "$project/crates" '. + [{
        id: ("path+file://" + $m + "#" + $n + "@" + $v),
        name: $n, version: $v, manifest_path: $m,
        publish: (if $pub == "" then null elif $pub == "false" then []
                  else ($pub | split(",")) end),
        dependencies: [$deps | select(length > 0) | split(",")[]
          | split("@") as [$d, $k]
          | {name: $d,
             kind: (if $k == null or $k == "ext" or $k == "out" then null
                    elif $k == "devv" then "dev" else $k end),
             req: (if $k == "dev" then "*" else "^1" end),
             path: (if $k == "ext" then null
                    elif $k == "out" then $root + "/../vendor/" + $d
                    else $root + "/" + $d end)}]}]' \
      <<< "$entries")"
  done
  printf '%s\n' "$entries" > "$MOCK_WORKSPACE_JSON"
}

# zeta <- mid <- alpha, so dependency order is the reverse of
# alphabetical; internal and private are not for crates.io.
standard_workspace() {
  make_workspace alpha:1.0.0:mid mid:1.0.0:zeta zeta:1.0.0:serde@ext \
    internal:1.0.0::false private:1.0.0::other
  export INPUT_WORKSPACE=true
}

# SHA-256 of the archive the cargo stand-in packages for NAME in a set.
set_sha256() {
  { printf '%s' "$1"; head -c "$MOCK_CRATE_SIZE" /dev/zero; } > "$workdir/archive"
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum < "$workdir/archive" | cut -d' ' -f1
  else
    shasum -a 256 < "$workdir/archive" | cut -d' ' -f1
  fi
}

# JSON digest map for the named crates, in the order given.
digest_map() {
  local name pairs=()
  for name in "$@"; do
    pairs+=("$name" "$(set_sha256 "$name")")
  done
  jq -cn '$ARGS.positional as $a | reduce range(0; $a | length; 2) as $i
    ({}; . + {($a[$i]): $a[$i + 1]})' --args "${pairs[@]}"
}

# Record NAME 1.0.0 in the stand-in index with DIGEST.
published_entry() {
  printf '{"name":"%s","vers":"1.0.0","cksum":"%s"}\n' "$1" "$2" \
    > "$MOCK_INDEX_DIR/$1"
}

last_output_value() {
  output_value "$1" | tail -n 1
}

### Default flow ###

@test "publishes with default inputs and records every output" {
  run_action

  [ "$status" -eq 0 ]
  assert_calls "$publish_calls"
  [ "$(cat "$GITHUB_OUTPUT")" = "$(printf '%s\n' cargo_version=1.98.1 \
    crate_name=example-crate crate_version=1.2.3 crate_size_bytes=32 \
    "crate_sha256=$(zero_sha256 32)" registry_status=absent \
    published=true publish_status=published)" ]
  [[ "$output" == *"Published example-crate 1.2.3 to crates.io"* ]]
}

@test "compiles in the project directory and runs every other stage elsewhere" {
  run_action

  [ "$status" -eq 0 ]
  [ "$(stage_env package 2)" = "$project" ]
  [ "$(cat "$MOCK_RUSTUP_LOG")" = "$project" ]
  local stage cwd
  for stage in version metadata dry-run repackage publish; do
    cwd="$(stage_env "$stage" 2)"
    [[ "$cwd" == "$RUNNER_TEMP"/rust-crate-publish.*/cwd ]]
  done
}

@test "pins every cargo stage to the toolchain rustup resolved" {
  export MOCK_TOOLCHAIN=1.80.0-x86_64-unknown-linux-gnu
  run_action

  [ "$status" -eq 0 ]
  [ "$(sort -u < <(awk -F'|' '{ print $8 }' "$MOCK_CARGO_ENV"))" \
    = 1.80.0-x86_64-unknown-linux-gnu ]
}

@test "packages into its own target directory, whatever CARGO_TARGET_DIR says" {
  export CARGO_TARGET_DIR="$workdir/consumer target"
  run_action

  [ "$status" -eq 0 ]
  [ "$(sort -u "$MOCK_CARGO_TARGETS" | wc -l)" -eq 1 ]
  [[ "$(head -1 "$MOCK_CARGO_TARGETS")" == "$RUNNER_TEMP"/rust-crate-publish.*/target ]]
  [ ! -e "$CARGO_TARGET_DIR" ]
}

@test "removes its temporary directory afterwards, on success or failure" {
  run_action
  [ "$status" -eq 0 ]
  export MOCK_FAIL_STAGE=dry-run
  run_action
  [ "$status" -eq 42 ]

  run ! compgen -G "$RUNNER_TEMP/rust-crate-publish.*"
}

### dry_run ###

@test "dry_run validates the package without a real publish" {
  export INPUT_DRY_RUN=true
  run_action

  [ "$status" -eq 0 ]
  assert_calls "$dry_run_calls"
  [ "$(output_value crate_size_bytes)" = 32 ]
  [ "$(output_value published)" = false ]
  [ "$(output_value publish_status)" = dry-run ]
}

@test "dry_run still fails when package validation fails" {
  export INPUT_DRY_RUN=true INPUT_MAX_CRATE_SIZE_BYTES=31
  run_action

  [ "$status" -eq 1 ]
  assert_calls $'version\nmetadata\npackage'
  [ "$(output_value publish_status)" = failed ]
}

@test "rejects non-boolean dry_run values before running anything" {
  local value
  for value in TRUE True yes 1 ' ' $'true\nfalse'; do
    export INPUT_DRY_RUN="$value"
    : > "$MOCK_CARGO_LOG"
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"dry_run must be 'true' or 'false'"* ]]
    assert_no_cargo
    [ ! -s "$MOCK_RUSTUP_LOG" ]
  done
}

@test "rejects non-boolean permit_fail and summary values" {
  export INPUT_PERMIT_FAIL=yes
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"permit_fail must be 'true' or 'false'"* ]]

  export INPUT_PERMIT_FAIL=false INPUT_SUMMARY=no
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"summary must be 'true' or 'false'"* ]]
  assert_no_cargo
}

### release_tag ###

@test "accepts an empty release tag" {
  export INPUT_RELEASE_TAG=""
  run_action

  [ "$status" -eq 0 ]
  [[ "$output" != *"matches release tag"* ]]
}

@test "accepts a matching release tag with or without one leading v" {
  local tag
  for tag in 1.2.3 v1.2.3; do
    export INPUT_RELEASE_TAG="$tag"
    run_action

    [ "$status" -eq 0 ]
    [[ "$output" == *"example-crate version 1.2.3 matches release tag"* ]]
  done
}

@test "rejects a mismatched release tag before packaging" {
  export INPUT_RELEASE_TAG=v2.0.0
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"does not match release tag (2.0.0)"* ]]
  assert_calls $'version\nmetadata'
}

@test "strips only one leading v" {
  export INPUT_RELEASE_TAG=vv1.2.3
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"does not match release tag (v1.2.3)"* ]]
  assert_calls $'version\nmetadata'
}

@test "rejects release tags outside the allowed character set" {
  local tag
  cd "$workdir"
  # shellcheck disable=SC2016 # a literal command substitution
  for tag in '$(touch unexpected-tag-command)' 'v1.2.3 ' $'v1.2.3\n::error::x' 'v1/2'; do
    export INPUT_RELEASE_TAG="$tag"
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"release_tag may contain only"* ]]
    [ ! -e unexpected-tag-command ]
    assert_no_cargo
  done
}

### max_crate_size_bytes ###

@test "enforces the packaged size limit at each boundary" {
  local case size limit expect_status
  local -a cases=(
    "10485759 10485760 0" # one byte below the default limit
    "10485760 10485760 0" # exactly at the default limit
    "10485761 10485760 1" # one byte above the default limit
    "32 31 1"             # smaller custom limit rejects
    "32 32 0"             # exactly at a custom limit
    "10485761 10485761 0" # larger custom limit accepts
  )
  for case in "${cases[@]}"; do
    read -r size limit expect_status <<< "$case"
    export MOCK_CRATE_SIZE="$size" INPUT_MAX_CRATE_SIZE_BYTES="$limit"
    reset_logs
    run_action

    [ "$status" -eq "$expect_status" ]
    [ "$(output_value crate_size_bytes)" = "$size" ]
    if [ "$expect_status" -ne 0 ]; then
      [[ "$output" == *"exceeding the ${limit}-byte limit"* ]]
      assert_calls $'version\nmetadata\npackage'
    fi
  done
}

@test "rejects malformed or out-of-range size limits before running cargo" {
  local limit
  # shellcheck disable=SC2016 # a literal command substitution
  for limit in -1 0 1.5 abc 010 1234567890123456789 \
    '$(touch unexpected-limit-command)'; do
    export INPUT_MAX_CRATE_SIZE_BYTES="$limit"
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"max_crate_size_bytes must be a positive integer"* ]]
    assert_no_cargo
  done
}

### path_prefix and manifest_path ###

@test "accepts path_prefix '.' with a nested manifest_path containing spaces" {
  export INPUT_PATH_PREFIX=. INPUT_MANIFEST_PATH="member crate/Cargo.toml"
  run_action

  [ "$status" -eq 0 ]
  [ "$(stage_env package 2)" = "$workdir" ]
}

@test "accepts an absolute path_prefix inside the workspace" {
  export INPUT_PATH_PREFIX="$project"
  run_action

  [ "$status" -eq 0 ]
}

@test "resolves a relative path_prefix against the workspace, not the cwd" {
  cd /
  run_action

  [ "$status" -eq 0 ]
  [ "$(stage_env package 2)" = "$project" ]
}

@test "accepts a workspace reached through a symlink" {
  ln -s "$workdir" "$BATS_TEST_TMPDIR/linked workspace"
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/linked workspace"
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value crate_name)" = example-crate ]
}

@test "rejects a path_prefix outside the workspace" {
  local prefix
  for prefix in / .. "$BATS_TEST_TMPDIR"; do
    export INPUT_PATH_PREFIX="$prefix"
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"path_prefix must resolve within the workspace"* ]]
    assert_no_cargo
  done
}

@test "rejects a path_prefix that is not a directory" {
  export INPUT_PATH_PREFIX="missing directory"
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"path_prefix is not a directory"* ]]
  assert_no_cargo
}

@test "rejects a manifest_path that is not a Cargo.toml" {
  local manifest
  for manifest in Cargo.lock "Cargo.toml.bak" "sub/NotCargo.toml"; do
    export INPUT_MANIFEST_PATH="$manifest"
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"manifest_path must name a Cargo.toml file"* ]]
    assert_no_cargo
  done
}

@test "rejects a missing manifest" {
  export INPUT_MANIFEST_PATH="absent/Cargo.toml"
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest_path does not exist below path_prefix"* ]]
  assert_no_cargo
}

@test "rejects a manifest_path that escapes the workspace" {
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  cp "$BATS_TEST_DIRNAME/fixtures/Cargo.toml" "$BATS_TEST_TMPDIR/outside/"
  export INPUT_MANIFEST_PATH="../../outside/Cargo.toml"
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest_path must resolve within the workspace"* ]]
  assert_no_cargo
}

@test "rejects a symlinked Cargo.toml, even one pointing outside the workspace" {
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  cp "$BATS_TEST_DIRNAME/fixtures/Cargo.toml" "$BATS_TEST_TMPDIR/outside/"
  rm "$project/Cargo.toml"
  ln -s "$BATS_TEST_TMPDIR/outside/Cargo.toml" "$project/Cargo.toml"
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest_path must not be a symlink"* ]]
  assert_no_cargo
}

@test "fails clearly when cargo is not on PATH" {
  local tool saved_path="$PATH"
  mkdir -p "$workdir/no-cargo"
  for tool in jq wc dirname env; do
    ln -s "$(command -v "$tool")" "$workdir/no-cargo/$tool"
  done
  export PATH="$workdir/no-cargo"
  run_action
  export PATH="$saved_path"

  [ "$status" -eq 1 ]
  [[ "$output" == *"required tool not found on PATH: cargo"* ]]
}

### Toolchain ###

@test "refuses a path toolchain for a real publish before running cargo" {
  export MOCK_TOOLCHAIN="/home/runner/work/repo/repo/.tools"
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"path-based Rust toolchain"*"will not publish"* ]]
  assert_no_cargo
  grep -Fx '### ❌ Failed at Check toolchain' "$GITHUB_STEP_SUMMARY"
}

@test "refuses a path toolchain for a release verification dry run" {
  export MOCK_TOOLCHAIN="/opt/custom" INPUT_DRY_RUN=true INPUT_RELEASE_TAG=v1.2.3
  run_action

  [ "$status" -eq 1 ]
  assert_no_cargo
}

@test "refuses a path toolchain for a two-job upload too" {
  export MOCK_TOOLCHAIN="/opt/custom"
  INPUT_EXPECTED_SHA256="$(zero_sha256 32)"
  export INPUT_EXPECTED_SHA256
  run_action

  [ "$status" -eq 1 ]
  assert_no_cargo
}

@test "a plain dry run with a path toolchain warns and stays in the project" {
  export MOCK_TOOLCHAIN="/opt/custom" INPUT_DRY_RUN=true
  run_action

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::path_prefix selects a path-based Rust toolchain"* ]]
  assert_calls "$dry_run_calls"
  [ "$(sort -u < <(awk -F'|' '{ print $2 }' "$MOCK_CARGO_ENV"))" = "$project" ]
  [ "$(sort -u < <(awk -F'|' '{ print $8 }' "$MOCK_CARGO_ENV"))" = unset ]
  grep -F '| Toolchain | ⚠️ Path toolchain <code>/opt/custom</code> |' \
    "$GITHUB_STEP_SUMMARY"
}

@test "rejects an unexpected toolchain name from rustup" {
  export MOCK_TOOLCHAIN='odd;name'
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"rustup reported an unexpected toolchain name"* ]]
  assert_no_cargo
}

@test "fails clearly when rustup cannot resolve a toolchain" {
  export MOCK_RUSTUP_FAIL=true
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"could not determine the Rust toolchain"* ]]
  assert_no_cargo
}

@test "works without rustup, leaving the toolchain unpinned" {
  local tool saved_path="$PATH" found
  rm "$workdir/bin/rustup"
  mkdir -p "$workdir/no-rustup"
  for tool in bash jq wc mktemp dirname env tr head awk grep cat tee rm \
    mkdir cp sed cut sort sha256sum shasum perl; do
    if found="$(command -v "$tool")"; then
      ln -s "$found" "$workdir/no-rustup/$tool"
    fi
  done
  export PATH="$workdir/bin:$workdir/no-rustup"
  run_action
  export PATH="$saved_path"

  [ "$status" -eq 0 ]
  [ "$(sort -u < <(awk -F'|' '{ print $8 }' "$MOCK_CARGO_ENV"))" = unset ]
  grep -F '(no rustup)' "$GITHUB_STEP_SUMMARY"
}

### Cargo metadata ###

@test "selects the workspace member matching the requested manifest" {
  export MOCK_INCLUDE_OTHER_PACKAGE=true
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value crate_name)" = example-crate ]
  [[ "$output" != *"other-crate"* ]]
}

@test "rejects invalid manifest JSON or missing manifest fields" {
  local manifest
  for manifest in 'not json' '{}' '{"name":"example-crate"}' '{"version":"1.2.3"}'; do
    printf '%s\n' "$manifest" > "$MOCK_MANIFEST_JSON"
    : > "$MOCK_CARGO_LOG"
    run_action

    [ "$status" -ne 0 ]
    assert_calls $'version\nmetadata'
  done
}

@test "refuses metadata values that would be unsafe as step outputs" {
  local manifest
  for manifest in '{"name":"evil\n::error::x","version":"1.2.3"}' \
    '{"name":"example-crate","version":"1.2.3\nextra=1"}'; do
    printf '%s\n' "$manifest" > "$MOCK_MANIFEST_JSON"
    reset_logs
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"cargo metadata returned an unexpected crate"* ]]
    [ "$(cat "$GITHUB_OUTPUT")" = $'cargo_version=1.98.1\npublished=false\npublish_status=failed' ]
    assert_calls $'version\nmetadata'
  done
}

### Cargo failures ###

@test "cargo failures stop the run, keep the exit code and name the stage" {
  local failure expected calls
  for failure in version metadata package dry-run repackage publish; do
    case "$failure" in
      version) expected="Check toolchain" calls=version ;;
      metadata) expected="Read crate metadata" calls=$'version\nmetadata' ;;
      package) expected="Package" calls=$'version\nmetadata\npackage' ;;
      dry-run) expected="Dry-run publish" calls=$'version\nmetadata\npackage\ndry-run' ;;
      repackage) expected="Confirm package unchanged" calls="$dry_run_calls" ;;
      publish) expected="Publish" calls="$publish_calls" ;;
    esac
    reset_logs
    export MOCK_FAIL_STAGE="$failure" INPUT_RELEASE_TAG=v1.2.3
    run_action

    [ "$status" -eq 42 ]
    assert_calls "$calls"
    [ "$(output_value published)" = false ]
    [ "$(output_value publish_status)" = failed ]
    grep -F "### ❌ Failed at $expected" "$GITHUB_STEP_SUMMARY"
    grep -Fx "$expected failed with exit status 42; see the step log for Cargo's output." \
      "$GITHUB_STEP_SUMMARY"
  done
}

@test "fails on a missing package file without publishing" {
  export MOCK_MISSING_PACKAGE=true
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"cargo package did not produce example-crate-1.2.3.crate"* ]]
  assert_calls $'version\nmetadata\npackage'
  run ! grep -q '^crate_size_bytes=' "$GITHUB_OUTPUT"
}

### Package integrity ###

@test "records the SHA-256 of the verified archive" {
  export INPUT_DRY_RUN=true
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value crate_sha256)" = "$(zero_sha256 32)" ]
  [[ "$output" == *"package SHA-256: $(zero_sha256 32)"* ]]
}

@test "refuses to publish a package that changed after verification" {
  export MOCK_TAMPER=true
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"example-crate package changed after verification; not publishing"* ]]
  assert_calls "$dry_run_calls"
  grep -F '### ❌ Failed at Confirm package unchanged' "$GITHUB_STEP_SUMMARY"
}

@test "a dry run also fails when the package changed after verification" {
  export MOCK_TAMPER=true INPUT_DRY_RUN=true
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"package changed after verification"* ]]
}

### expected_sha256: upload without compiling ###

@test "expected_sha256 uploads the matching archive without compiling it" {
  INPUT_EXPECTED_SHA256="$(zero_sha256 32)"
  export INPUT_EXPECTED_SHA256
  run_action

  [ "$status" -eq 0 ]
  assert_calls $'version\nmetadata\nrepackage\ndry-run\nrepackage\npublish'
  [[ "$output" == *"example-crate package matches expected_sha256"* ]]
  grep -F 'Matches the digest from an earlier job; not compiled here' \
    "$GITHUB_STEP_SUMMARY"
}

@test "expected_sha256 refuses a different archive and names the cargo version" {
  INPUT_EXPECTED_SHA256="$(zero_sha256 31)"
  export INPUT_EXPECTED_SHA256 MOCK_CARGO_VERSION=1.97.0
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"does not match expected_sha256; not publishing"*"cargo 1.97.0"* ]]
  assert_calls $'version\nmetadata\nrepackage'
  grep -F '### ❌ Failed at Match verified digest' "$GITHUB_STEP_SUMMARY"
}

@test "a dry run's crate_sha256 feeds expected_sha256 in a later run" {
  export INPUT_DRY_RUN=true
  run_action
  [ "$status" -eq 0 ]
  local digest
  digest="$(output_value crate_sha256)"

  export INPUT_DRY_RUN=false INPUT_EXPECTED_SHA256="$digest"
  : > "$MOCK_CARGO_LOG"
  run_action

  [ "$status" -eq 0 ]
  run ! grep -qx package "$MOCK_CARGO_LOG"
}

@test "rejects a malformed expected_sha256 before running cargo" {
  local digest
  for digest in abc "$(zero_sha256 32 | tr 'a-f' 'A-F')" \
    "$(zero_sha256 32)0" "$(zero_sha256 32 | cut -c2-)g"; do
    export INPUT_EXPECTED_SHA256="$digest"
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"expected_sha256 must be 64 lowercase hexadecimal characters"* ]]
    assert_no_cargo
  done
}

### crates.io version check ###

@test "looks the crate up at its sparse index path" {
  local name expected
  for name in a ab abc Example-Crate; do
    case "$name" in
      a) expected=1/a ;;
      ab) expected=2/ab ;;
      abc) expected=3/a/abc ;;
      Example-Crate) expected=ex/am/example-crate ;;
    esac
    printf '{"name":"%s","version":"1.2.3"}\n' "$name" > "$MOCK_MANIFEST_JSON"
    export INPUT_DRY_RUN=true
    run_action

    [ "$status" -eq 0 ]
    [ "$(head -1 "$MOCK_CURL_LOG")" = "https://index.crates.io/$expected" ]
  done
}

@test "an identical published archive skips the upload" {
  index_entry 1.2.3 "$(zero_sha256 32)"
  run_action

  [ "$status" -eq 0 ]
  assert_calls $'version\nmetadata\npackage'
  [ "$(output_value registry_status)" = identical ]
  [ "$(output_value publish_status)" = skipped ]
  [ "$(output_value published)" = false ]
  grep -Fx '### ⛔️ Skipped: previously published: example-crate 1.2.3' \
    "$GITHUB_STEP_SUMMARY"
  grep -F '| Link | 🔗 https://crates.io/crates/example-crate/1.2.3 |' \
    "$GITHUB_STEP_SUMMARY"
}

@test "an identical published archive lets a dry run complete" {
  index_entry 1.2.3 "$(zero_sha256 32)"
  export INPUT_DRY_RUN=true INPUT_RELEASE_TAG=v1.2.3
  run_action

  [ "$status" -eq 0 ]
  assert_calls "$dry_run_calls"
  [ "$(output_value registry_status)" = identical ]
}

@test "different published content fails a real publish before any upload" {
  index_entry 1.2.3 "$(zero_sha256 99)"
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"already on crates.io with different content (published SHA-256 $(zero_sha256 99))"* ]]
  assert_calls $'version\nmetadata\npackage'
  [ "$(output_value registry_status)" = different ]
  grep -F '| crates.io | ❌ Already published with different content |' \
    "$GITHUB_STEP_SUMMARY"
}

@test "different published content fails a release verification dry run" {
  index_entry 1.2.3 "$(zero_sha256 99)"
  export INPUT_DRY_RUN=true INPUT_RELEASE_TAG=v1.2.3
  run_action

  [ "$status" -eq 1 ]
  [ "$(output_value publish_status)" = failed ]
}

@test "different published content only warns a plain dry run" {
  index_entry 1.2.3 "$(zero_sha256 99)"
  export INPUT_DRY_RUN=true
  run_action

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::example-crate 1.2.3 is already on crates.io with different content; bump the version"* ]]
  assert_calls "$dry_run_calls"
  grep -F '| crates.io | ⚠️ Already published with different content |' \
    "$GITHUB_STEP_SUMMARY"
}

@test "ignores build metadata and other versions in the index" {
  index_entry 1.2.3+build.7 "$(zero_sha256 32)"
  run_action
  [ "$status" -eq 0 ]
  [ "$(output_value registry_status)" = identical ]

  reset_logs
  index_entry 1.2.2 "$(zero_sha256 99)"
  run_action
  [ "$status" -eq 0 ]
  [ "$(output_value registry_status)" = absent ]
  [ "$(output_value publish_status)" = published ]
}

@test "fails closed when the crates.io index cannot be read" {
  local case
  for case in unreachable http-500 bad-json no-cksum; do
    unset MOCK_CURL_FAIL MOCK_INDEX_STATUS MOCK_INDEX_BODY
    case "$case" in
      unreachable) export MOCK_CURL_FAIL=true ;;
      http-500) export MOCK_INDEX_STATUS=500 ;;
      bad-json)
        printf 'not json\n' > "$workdir/index.json"
        export MOCK_INDEX_STATUS=200 MOCK_INDEX_BODY="$workdir/index.json"
        ;;
      no-cksum)
        printf '{"name":"example-crate","vers":"1.2.3"}\n' > "$workdir/index.json"
        export MOCK_INDEX_STATUS=200 MOCK_INDEX_BODY="$workdir/index.json"
        ;;
    esac
    reset_logs
    export INPUT_DRY_RUN=true
    run_action

    [ "$status" -eq 1 ]
    grep -F '### ❌ Failed at Check crates.io' "$GITHUB_STEP_SUMMARY"
  done
}

@test "a failed upload that crates.io nevertheless holds counts as skipped" {
  printf '{"name":"example-crate","vers":"1.2.3","cksum":"%s"}\n' \
    "$(zero_sha256 32)" > "$workdir/late.json"
  export MOCK_FAIL_STAGE=publish MOCK_INDEX_STATUS_2=200 \
    MOCK_INDEX_BODY_2="$workdir/late.json"
  run_action

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MOCK_CURL_LOG")" -eq 2 ]
  [ "$(output_value publish_status | tail -1)" = skipped ]
  [[ "$output" == *"crates.io already holds this exact archive"* ]]
}

@test "a failed upload crates.io does not hold keeps Cargo's exit code" {
  export MOCK_FAIL_STAGE=publish
  run_action

  [ "$status" -eq 42 ]
  [ "$(wc -l < "$MOCK_CURL_LOG")" -eq 2 ]
}

@test "a failed re-check after a failed upload still keeps Cargo's exit code" {
  printf 'not json\n' > "$workdir/broken.json"
  local case
  for case in http-500 bad-json; do
    unset MOCK_INDEX_STATUS_2 MOCK_INDEX_BODY_2
    case "$case" in
      http-500) export MOCK_INDEX_STATUS_2=500 ;;
      bad-json) export MOCK_INDEX_STATUS_2=200 \
        MOCK_INDEX_BODY_2="$workdir/broken.json" ;;
    esac
    reset_logs
    export MOCK_FAIL_STAGE=publish
    run_action

    [ "$status" -eq 42 ]
    [ "$(wc -l < "$MOCK_CURL_LOG")" -eq 2 ]
    grep -Fx "Publish failed with exit status 42; see the step log for Cargo's output." \
      "$GITHUB_STEP_SUMMARY"
  done
}

### registry: named Cargo registries ###

readonly staging_index="sparse+https://index.staging.example/"
readonly staging_vars="CARGO_REGISTRIES_STAGING_INDEX=$staging_index "

# Target a registry named 'staging' with a sparse index stand-in.
use_staging() {
  export INPUT_REGISTRY=staging MOCK_EXPECT_REGISTRY=staging
  export CARGO_REGISTRIES_STAGING_INDEX="$staging_index"
}

@test "an empty registry publishes to crates.io as before" {
  local name
  for name in "" crates-io; do
    export INPUT_REGISTRY="$name"
    reset_logs
    run_action

    [ "$status" -eq 0 ]
    assert_calls "$publish_calls"
    [ "$(cat "$MOCK_CURL_LOG")" = "https://index.crates.io/ex/am/example-crate" ]
    [[ "$output" == *"Published example-crate 1.2.3 to crates.io"* ]]
    grep -Fx '| Mode | Publish to crates.io |' "$GITHUB_STEP_SUMMARY"
  done
}

@test "rejects other spellings of crates-io, which share its settings" {
  local name
  for name in crates_io CRATES-IO Crates_Io; do
    export INPUT_REGISTRY="$name" CARGO_REGISTRIES_CRATES_IO_INDEX="$staging_index"
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"registry must be 'crates-io' or empty to publish to crates.io"* ]]
    assert_no_cargo
  done
}

@test "a named registry gets --registry on every package and publish call" {
  use_staging
  run_action

  [ "$status" -eq 0 ]
  assert_calls "$publish_calls"
  [ "$(cat "$MOCK_CURL_LOG")" = "$(printf '%s\n' \
    https://index.staging.example/config.json \
    https://index.staging.example/ex/am/example-crate)" ]
  [[ "$output" == *"Registry: staging, index https://index.staging.example, API https://api.example.test"* ]]
  [[ "$output" == *"Published example-crate 1.2.3 to staging registry"* ]]
  [ "$(output_value published)" = true ]
}

@test "expected_sha256 packages for the named registry too" {
  use_staging
  INPUT_EXPECTED_SHA256="$(zero_sha256 32)"
  export INPUT_EXPECTED_SHA256
  run_action

  [ "$status" -eq 0 ]
  assert_calls $'version\nmetadata\nrepackage\ndry-run\nrepackage\npublish'
}

@test "maps a hyphenated registry name to Cargo's variable names" {
  export INPUT_REGISTRY=my-registry MOCK_EXPECT_REGISTRY=my-registry
  export CARGO_REGISTRIES_MY_REGISTRY_INDEX="$staging_index"
  export INPUT_REGISTRY_TOKEN=input-token
  run_action

  [ "$status" -eq 0 ]
  [[ "$(stage_vars publish)" == *"CARGO_REGISTRIES_MY_REGISTRY_TOKEN=input-token "* ]]
}

@test "fails clearly when a named registry has no index URL" {
  local permit
  for permit in false true; do
    export INPUT_REGISTRY=staging INPUT_PERMIT_FAIL="$permit"
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"registry 'staging' needs its index URL in CARGO_REGISTRIES_STAGING_INDEX"* ]]
    assert_no_cargo
    [ ! -s "$MOCK_CURL_LOG" ]
  done
}

@test "rejects registry names outside the allowed character set" {
  local name
  for name in 'a b' 'a;b' '../x' 'a.b' 'a/b' $'staging\n::error::injected' \
    -private --version 9reg; do
    export INPUT_REGISTRY="$name"
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"registry must start with a letter or _ and may contain only: A-Z a-z 0-9 _ -"* ]]
    [[ "$output" != *"injected"* ]]
    assert_no_cargo
  done
}

@test "requires a sparse+https index URL for a named registry" {
  local index
  for index in https://github.com/example/index sparse+http://index.example/ \
    'sparse+https://index.example/a b' git+https://index.example/ \
    $'sparse+https://index.example/\n::error::injected' sparse+https:///index \
    sparse+https://:443/ 'sparse+https://user:injected@index.example/' \
    'sparse+https://injected@index.example/' sparse+https://?q \
    'sparse+https://index.example/cargo?x=1' 'sparse+https://index.example/#x'; do
    export INPUT_REGISTRY=staging CARGO_REGISTRIES_STAGING_INDEX="$index"
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"CARGO_REGISTRIES_STAGING_INDEX must be a sparse index URL starting with 'sparse+https://', with a host, no credentials and no query"* ]]
    [[ "$output" != *"injected"* ]]
    assert_no_cargo
    [ ! -s "$MOCK_CURL_LOG" ]
  done
}

@test "requires the trailing slash Cargo needs on a sparse index URL" {
  local index
  for index in sparse+https://index.example sparse+https://index.example/cargo; do
    export INPUT_REGISTRY=staging CARGO_REGISTRIES_STAGING_INDEX="$index"
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"CARGO_REGISTRIES_STAGING_INDEX must end in '/', as Cargo requires of a sparse index"* ]]
    assert_no_cargo
    [ ! -s "$MOCK_CURL_LOG" ]
  done
}

@test "drops trailing slashes from the index URL" {
  use_staging
  export CARGO_REGISTRIES_STAGING_INDEX="sparse+https://index.staging.example///"
  export INPUT_DRY_RUN=true
  run_action

  [ "$status" -eq 0 ]
  [ "$(head -1 "$MOCK_CURL_LOG")" = https://index.staging.example/config.json ]
}

@test "refuses a registry whose index needs authentication" {
  use_staging
  local case
  for case in status body; do
    if [ "$case" = status ]; then
      export MOCK_CONFIG_STATUS=401
    else
      export MOCK_CONFIG_STATUS=200
      export MOCK_CONFIG_BODY='{"api":"https://api.example.test","auth-required":true}'
    fi
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"this action reads registry indexes without credentials"* ]]
    grep -F 'Failed at Read registry config' "$GITHUB_STEP_SUMMARY"
    assert_no_cargo
    reset_logs
  done
}

@test "refuses a registry config without an HTTPS api URL" {
  use_staging
  local body
  for body in '{"dl":"https://dl.example.test"}' '{"api":"http://api.example.test"}' \
    '{"api":"https://api.example.test/a b"}' '{"api":7}' '[]' 'not json' \
    '{"api":"https:///upload"}' '{"api":"https://?query"}' \
    '{"api":"https://user:secret@api.example.test"}' \
    '{"api":"https://api.example.test/cargo?x=1"}' \
    '{"api":"https://api.example.test/#x"}'; do
    export MOCK_CONFIG_BODY="$body"
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"staging registry index config.json"* ]]
    [[ "$output" != *secret* ]]
    assert_no_cargo
  done
}

@test "accepts index and api URLs with a port and path, and names led by _" {
  export INPUT_REGISTRY=_staging MOCK_EXPECT_REGISTRY=_staging
  export CARGO_REGISTRIES__STAGING_INDEX="sparse+https://index.example:8443/cargo/"
  export MOCK_CONFIG_BODY='{"api":"https://api.example.test:8443/cargo"}'
  export INPUT_DRY_RUN=true
  run_action

  [ "$status" -eq 0 ]
  [ "$(head -1 "$MOCK_CURL_LOG")" = https://index.example:8443/cargo/config.json ]
  [[ "$output" == *"API https://api.example.test:8443/cargo"* ]]
}

@test "fails closed when the registry config cannot be read" {
  use_staging
  export MOCK_CONFIG_STATUS=500
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"the staging registry index answered HTTP 500 for config.json"* ]]
  assert_no_cargo

  export MOCK_CURL_FAIL=true
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"could not reach the staging registry index"* ]]
}

@test "an identical archive on a named registry skips the upload" {
  use_staging
  index_entry 1.2.3 "$(zero_sha256 32)"
  run_action

  [ "$status" -eq 0 ]
  assert_calls $'version\nmetadata\npackage'
  [ "$(tail -1 "$MOCK_CURL_LOG")" = https://index.staging.example/ex/am/example-crate ]
  [[ "$output" == *"already on staging registry with identical content"* ]]
  [ "$(output_value publish_status)" = skipped ]
  grep -F '| staging registry | ✅ Already published, identical archive |' \
    "$GITHUB_STEP_SUMMARY"
}

@test "different content on a named registry fails a real publish" {
  use_staging
  index_entry 1.2.3 "$(zero_sha256 99)"
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"already on staging registry with different content (published SHA-256 $(zero_sha256 99)). Cargo will not publish a version the registry already holds: release a new one."* ]]
  assert_calls $'version\nmetadata\npackage'
  grep -F 'Failed at Check staging registry' "$GITHUB_STEP_SUMMARY"
}

@test "a named registry may answer 410 or 451 for an absent crate" {
  local code
  for code in 410 451; do
    use_staging
    export MOCK_INDEX_STATUS="$code" INPUT_DRY_RUN=true
    run_action

    [ "$status" -eq 0 ]
    [ "$(output_value registry_status)" = absent ]

    # crates.io answers 404, so anything else there still fails closed.
    unset INPUT_REGISTRY MOCK_EXPECT_REGISTRY
    reset_logs
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"the crates.io index answered HTTP $code"* ]]
    reset_logs
  done
}

@test "the dry run's already-exists warning is never an annotation" {
  export INPUT_DRY_RUN=true
  local where
  # shellcheck disable=SC2016 # Cargo quotes registry names in backticks
  for where in 'crates.io index' '`staging` index'; do
    if [ "$where" != 'crates.io index' ]; then
      use_staging
    fi
    export MOCK_DRY_RUN_EXISTS="$where"
    reset_logs
    run_action

    [ "$status" -eq 0 ]
    [[ "$output" == *"already exists on $where"* ]]
    [[ "$output" != *"::warning title=cargo::crate"* ]]
  done
}

@test "registry_token reaches a named registry's upload alone, under its name" {
  use_staging
  export INPUT_REGISTRY_TOKEN=input-token CARGO_REGISTRY_TOKEN=crates-io-token
  run_action

  [ "$status" -eq 0 ]
  local stage
  for stage in version metadata package dry-run repackage; do
    [ "$(stage_vars "$stage")" = "$staging_vars" ]
  done
  [ "$(cat "$MOCK_RUSTUP_VARS")" = "$staging_vars" ]
  [ "$(stage_vars publish)" = "CARGO_REGISTRIES_STAGING_CREDENTIAL_PROVIDER=cargo:token ${staging_vars}CARGO_REGISTRIES_STAGING_TOKEN=input-token CARGO_REGISTRY_GLOBAL_CREDENTIAL_PROVIDERS=cargo:token " ]
}

@test "a named registry's upload keeps the caller's token for it, and no other" {
  use_staging
  export_scrubbed_variables
  export CARGO_REGISTRIES_STAGING_TOKEN=staging-token
  run_action

  [ "$status" -eq 0 ]
  local stage
  local kept="CARGO_REGISTRIES_PRIVATE_INDEX=sparse+https://private.example/ $staging_vars"
  for stage in version metadata package dry-run repackage; do
    [ "$(stage_vars "$stage")" = "$kept" ]
  done
  [ "$(stage_vars publish)" = "${kept}CARGO_REGISTRIES_STAGING_TOKEN=staging-token " ]
}

@test "a named registry's summary names it and links nowhere" {
  use_staging
  run_action

  [ "$status" -eq 0 ]
  grep -Fx '| Mode | Publish to staging registry |' "$GITHUB_STEP_SUMMARY"
  grep -Fx '| staging registry | ✅ Version not yet published |' \
    "$GITHUB_STEP_SUMMARY"
  if grep -F -e '| Link |' -e 'crates.io' "$GITHUB_STEP_SUMMARY"; then
    false
  fi
}

### permit_fail ###

@test "permit_fail reports success for a failed stage, with a warning" {
  export INPUT_PERMIT_FAIL=true INPUT_RELEASE_TAG=v9.9.9
  run_action

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::Stage 'Verify release tag' failed (exit 1)"* ]]
  [ "$(output_value published)" = false ]
  [ "$(output_value publish_status)" = failed ]
  grep -Fx '### ⚠️ Failed at Verify release tag (permitted): example-crate 1.2.3' \
    "$GITHUB_STEP_SUMMARY"
}

@test "permit_fail covers a failed upload" {
  export INPUT_PERMIT_FAIL=true MOCK_FAIL_STAGE=publish
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value published)" = false ]
}

@test "permit_fail never masks invalid inputs" {
  export INPUT_PERMIT_FAIL=true INPUT_DRY_RUN=maybe
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" != *"permit_fail is 'true'"* ]]
}

@test "permit_fail covers a failure to prepare the temporary directory" {
  export RUNNER_TEMP="$workdir/missing runner temp"
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not create a temporary directory"* ]]

  export INPUT_PERMIT_FAIL=true
  run_action
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::Stage 'Prepare workspace' failed (exit 1)"* ]]
  assert_no_cargo
}

### Credentials ###

@test "withholds ambient registry tokens from every stage but the upload" {
  export CARGO_REGISTRY_TOKEN="ambient token"
  export CARGO_REGISTRIES_CRATES_IO_TOKEN="ambient named token"
  run_action

  [ "$status" -eq 0 ]
  local stage
  for stage in version metadata package dry-run repackage; do
    [ "$(stage_env "$stage" 3)" = unset ]
    [ "$(stage_env "$stage" 4)" = unset ]
  done
  [ "$(stage_env publish 3)" = "ambient token" ]
  [ "$(stage_env publish 4)" = "ambient named token" ]
  [[ "$output" != *"ambient token"* ]]
}

@test "registry_token reaches the upload alone and never as an input variable" {
  export INPUT_REGISTRY_TOKEN="input-token"
  export CARGO_REGISTRY_TOKEN="ambient-token"
  run_action

  [ "$status" -eq 0 ]
  local stage
  for stage in version metadata package dry-run repackage publish; do
    [ "$(stage_env "$stage" 6)" = unset ]
  done
  [ "$(stage_env package 3)" = unset ]
  [ "$(stage_env publish 3)" = "input-token" ]
}

@test "registry_token is masked and not otherwise printed" {
  export INPUT_REGISTRY_TOKEN="input-token"
  run_action

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "::add-mask::input-token" ]
  [ "$(printf '%s\n' "$output" | grep -c input-token)" -eq 1 ]
}

@test "rejects a registry_token containing whitespace" {
  export INPUT_REGISTRY_TOKEN=$'first\nsecond'
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"registry_token must not contain whitespace"* ]]
  [[ "$output" != *"second"* ]]
  assert_no_cargo
}

@test "registry_token forces Cargo's built-in token provider for the upload" {
  export INPUT_REGISTRY_TOKEN=input-token
  run_action

  [ "$status" -eq 0 ]
  [ "$(stage_env publish 7)" = cargo:token ]
  [ "$(stage_env dry-run 7)" = unset ]
}

@test "without registry_token, the caller's credential provider stays in charge" {
  run_action

  [ "$status" -eq 0 ]
  [ "$(stage_env publish 7)" = unset ]
}

@test "withholds GitHub OIDC request variables from every cargo stage" {
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN="oidc-request-token"
  export ACTIONS_ID_TOKEN_REQUEST_URL="https://example.invalid/oidc"
  run_action

  [ "$status" -eq 0 ]
  local stage
  for stage in version metadata package dry-run repackage publish; do
    [ "$(stage_env "$stage" 5)" = unset ]
  done
}

# Every value differs, so a variable that slips through shows exactly.
export_scrubbed_variables() {
  export CARGO_REGISTRY_TOKEN=registry-token
  export CARGO_REGISTRIES_CRATES_IO_TOKEN=crates-io-token
  export CARGO_REGISTRIES_PRIVATE_TOKEN=private-token
  export CARGO_REGISTRIES_PRIVATE_INDEX=sparse+https://private.example/
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN=oidc-token
  export ACTIONS_ID_TOKEN_REQUEST_URL=https://oidc.example/
  export ACTIONS_RUNTIME_TOKEN=runtime-token
  export GITHUB_ENV="$workdir/env file" GITHUB_PATH="$workdir/path file"
  export GITHUB_STATE="$workdir/state file"
}

@test "withholds every token and runner command file from cargo and rustup" {
  export_scrubbed_variables
  run_action

  [ "$status" -eq 0 ]
  local stage kept="CARGO_REGISTRIES_PRIVATE_INDEX=sparse+https://private.example/ "
  for stage in version metadata package dry-run repackage; do
    [ "$(stage_vars "$stage")" = "$kept" ]
  done
  [ "$(cat "$MOCK_RUSTUP_VARS")" = "$kept" ]
  # The action's own writes still land.
  [ "$(output_value publish_status)" = published ]
  [ -s "$GITHUB_STEP_SUMMARY" ]
}

@test "the upload sees crates.io's token variables and nothing else scrubbed" {
  export_scrubbed_variables
  run_action

  [ "$status" -eq 0 ]
  [ "$(stage_vars publish)" = "CARGO_REGISTRIES_CRATES_IO_TOKEN=crates-io-token CARGO_REGISTRIES_PRIVATE_INDEX=sparse+https://private.example/ CARGO_REGISTRY_TOKEN=registry-token " ]
}

@test "leaves Cargo credential files untouched" {
  local credentials=$'[registry]\ntoken = "consumer-file-token"'
  printf '%s\n' "$credentials" > "$CARGO_HOME/credentials.toml"
  run_action

  [ "$status" -eq 0 ]
  [ "$(cat "$CARGO_HOME/credentials.toml")" = "$credentials" ]
  [[ "$output" != *"consumer-file-token"* ]]
}

### Trusted Publisher notice ###

@test "names the Trusted Publisher config surface before a real publish" {
  export GITHUB_REPOSITORY="example-org/example-crate"
  export GITHUB_WORKFLOW_REF="example-org/example-crate/.github/workflows/release.yaml@refs/tags/v1.2.3"
  run_action

  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::Trusted Publisher config surface for example-crate: repository example-org/example-crate, workflow .github/workflows/release.yaml."* ]]
}

@test "falls back to unknown repository and workflow outside GitHub Actions" {
  run_action

  [ "$status" -eq 0 ]
  [[ "$output" == *"repository unknown, workflow unknown."* ]]
}

@test "omits the Trusted Publisher notice for a dry run" {
  export INPUT_DRY_RUN=true
  run_action

  [ "$status" -eq 0 ]
  [[ "$output" != *"Trusted Publisher"* ]]
}

### Cargo warnings ###

@test "turns Cargo warnings into one annotation each and lists them" {
  export MOCK_CARGO_WARNING="manifest has no license or license-file"
  run_action

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^::warning title=cargo::manifest has no license or license-file$')" -eq 1 ]
  [[ "$output" != *"::warning title=cargo::aborting upload"* ]]
  grep -Fx -- '- Cargo: manifest has no license or license-file' \
    "$GITHUB_STEP_SUMMARY"
}

@test "encodes percent signs in Cargo warning annotations" {
  export MOCK_CARGO_WARNING="100% odd"
  run_action

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning title=cargo::100%25 odd"* ]]
}

### Job summary ###

@test "a successful publish writes the complete summary" {
  export INPUT_RELEASE_TAG=v1.2.3
  run_action

  [ "$status" -eq 0 ]
  local sha
  sha="$(zero_sha256 32)"
  expected=$(cat << MARKDOWN

## 🦀 Rust Crate Publish

### 🚀 Published: example-crate 1.2.3

| Check | Result |
| --- | --- |
| Mode | Publish to crates.io |
| Manifest | <code>member crate/Cargo.toml</code> |
| Toolchain | <code>cargo 1.98.1</code> via <code>stable-x86_64-unknown-linux-gnu</code> |
| Release tag | ✅ <code>v1.2.3</code> matches |
| Verification | ✅ Compiled and verified in this job |
| Package size | ✅ 32 B of the 10.0 MiB limit |
| crates.io | ✅ Version not yet published |
| SHA-256 | <code>$sha</code> |
| Link | 🔗 https://crates.io/crates/example-crate/1.2.3 |
MARKDOWN
  )
  [ "$(cat "$GITHUB_STEP_SUMMARY")" = "$expected" ]
}

@test "a dry run summary never claims publication" {
  export INPUT_DRY_RUN=true
  run_action

  [ "$status" -eq 0 ]
  grep -Fx '### ✅ Dry run passed: example-crate 1.2.3' "$GITHUB_STEP_SUMMARY"
  grep -F '| Mode | Dry run: nothing uploaded |' "$GITHUB_STEP_SUMMARY"
  grep -F '| Release tag | ➖ Not requested |' "$GITHUB_STEP_SUMMARY"
  run ! grep -q -e 'Published' -e '| Link |' "$GITHUB_STEP_SUMMARY"
}

@test "a tag mismatch summary explains the failure and marks later checks" {
  export INPUT_RELEASE_TAG=v9.0.0
  run_action

  [ "$status" -eq 1 ]
  grep -Fx '### ❌ Failed at Verify release tag: example-crate 1.2.3' \
    "$GITHUB_STEP_SUMMARY"
  grep -Fx 'example-crate Cargo.toml version (1.2.3) does not match release tag (9.0.0)' \
    "$GITHUB_STEP_SUMMARY"
  grep -F '| Release tag | ❌ <code>v9.0.0</code> does not match <code>1.2.3</code> |' \
    "$GITHUB_STEP_SUMMARY"
  grep -F '| Package size | ⏸️ Not reached |' "$GITHUB_STEP_SUMMARY"
}

@test "an oversize summary reports readable sizes" {
  export MOCK_CRATE_SIZE=2097152 INPUT_MAX_CRATE_SIZE_BYTES=1048576
  run_action

  [ "$status" -eq 1 ]
  grep -F '| Package size | ❌ 2.0 MiB, over the 1.0 MiB limit |' \
    "$GITHUB_STEP_SUMMARY"
}

@test "summary 'false' writes no summary" {
  export INPUT_SUMMARY=false
  run_action

  [ "$status" -eq 0 ]
  [ ! -s "$GITHUB_STEP_SUMMARY" ]
}

@test "multiple crate invocations append without overwriting earlier summaries" {
  printf 'Existing job notes\n' > "$GITHUB_STEP_SUMMARY"
  run_action
  [ "$status" -eq 0 ]
  export INPUT_DRY_RUN=true
  run_action

  [ "$status" -eq 0 ]
  [ "$(grep -c '^## 🦀 Rust Crate Publish$' "$GITHUB_STEP_SUMMARY")" -eq 2 ]
  grep -Fx 'Existing job notes' "$GITHUB_STEP_SUMMARY"
  grep -F '### 🚀 Published' "$GITHUB_STEP_SUMMARY"
  grep -F '### ✅ Dry run passed' "$GITHUB_STEP_SUMMARY"
}

@test "local runs without GitHub output or summary paths still succeed" {
  unset GITHUB_STEP_SUMMARY GITHUB_OUTPUT
  run_action

  [ "$status" -eq 0 ]
  assert_calls "$publish_calls"
}

@test "summary write errors warn without replacing the exit status" {
  export GITHUB_STEP_SUMMARY="$workdir"
  run_action
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::Could not write crate publishing job summary"* ]]

  export MOCK_FAIL_STAGE=publish
  run_action
  [ "$status" -eq 42 ]
  [[ "$output" == *"::warning::Could not write crate publishing job summary"* ]]
}

@test "summary helpers escape markup and format sizes" {
  # shellcheck disable=SC2016 # expanded by the inner shell
  run "$BASH" -c 'source "$1"; summary_cell "$2"; echo; summary_code "$2"' -- \
    "$repo_dir/scripts/job-summary.sh" $'<tag> & | `value`\r\nnext'

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = '&lt;tag&gt; &amp; &#124; &#96;value&#96;  next' ]
  [ "${lines[1]}" = '<code>&lt;tag&gt; &amp; &#124; &#96;value&#96;  next</code>' ]

  # shellcheck disable=SC2016 # expanded by the inner shell
  run "$BASH" -c 'source "$1"; for b in 0 1023 1024 1536 10485760 1073741824; do human_bytes "$b"; echo; done' -- \
    "$repo_dir/scripts/job-summary.sh"
  [ "$output" = $'0 B\n1023 B\n1.0 KiB\n1.5 KiB\n10.0 MiB\n1.0 GiB' ]
}

@test "summary contains no credentials or authentication claims" {
  export INPUT_REGISTRY_TOKEN="private-consumer-token"
  run_action

  [ "$status" -eq 0 ]
  run ! grep -q private-consumer-token "$GITHUB_STEP_SUMMARY"
  run ! grep -iq 'auth\|token' "$GITHUB_STEP_SUMMARY"
}

### Workspace selection ###

@test "workspace publishes every crates.io member as one set in dependency order" {
  standard_workspace
  run_action

  [ "$status" -eq 0 ]
  assert_calls "$publish_calls"
  [ "$(cat "$MOCK_CARGO_SETS")" = "$(printf '%s\n' \
    'package zeta mid alpha' 'dry-run zeta mid alpha' \
    'repackage zeta mid alpha' 'publish zeta mid alpha')" ]
  [ "$(cat "$GITHUB_OUTPUT")" = "$(printf '%s\n' cargo_version=1.98.1 \
    'crate_name=zeta mid alpha' \
    'crate_version={"zeta":"1.0.0","mid":"1.0.0","alpha":"1.0.0"}' \
    'crate_size_bytes={"zeta":36,"mid":35,"alpha":37}' \
    "crate_sha256=$(digest_map zeta mid alpha)" \
    'registry_status={"zeta":"absent","mid":"absent","alpha":"absent"}' \
    published=true publish_status=published)" ]
  [[ "$output" == *"::notice::Skipping workspace members whose package.publish setting excludes crates.io: internal, private"* ]]
  [ "$(cat "$MOCK_CURL_LOG")" = "$(printf '%s\n' \
    https://index.crates.io/ze/ta/zeta https://index.crates.io/3/m/mid \
    https://index.crates.io/al/ph/alpha)" ]
  [ "$(stage_env package 2)" = "$project" ]
}

@test "orders by normal, build and versioned dev dependencies only" {
  make_workspace a:1.0.0:b@build b:1.0.0:c@devv c:1.0.0:d@dev d:1.0.0:a@ext
  export INPUT_WORKSPACE=true INPUT_DRY_RUN=true
  run_action

  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$MOCK_CARGO_SETS")" = "package c d b a" ]
  [ "$(output_value crate_name)" = "c d b a" ]
}

@test "a path crate outside the workspace is no member edge" {
  make_workspace a:1.0.0:b@out b:1.0.0:a
  export INPUT_WORKSPACE=true INPUT_DRY_RUN=true
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value crate_name)" = "a b" ]
}

# A version-only dependency that [patch.crates-io] points at a member
# carries no path, as '@ext' models. Cargo 1.99 packages and uploads
# such a dependent first, against the crates.io release, so the reported
# order must follow suit rather than put the member first.
@test "a version-only dependency patched to a member is no member edge" {
  make_workspace app:1.0.0:core@ext core:1.0.0:
  export INPUT_WORKSPACE=true INPUT_DRY_RUN=true
  run_action

  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$MOCK_CARGO_SETS")" = "package app core" ]
  [ "$(output_value crate_name)" = "app core" ]
}

@test "refuses selected crates that depend on each other in a cycle" {
  make_workspace a:1.0.0:b b:1.0.0:a@devv
  export INPUT_WORKSPACE=true
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"the selected crates depend on each other in a cycle"* ]]
  assert_calls $'version\nmetadata'
}

@test "exclude leaves members out of the workspace selection" {
  standard_workspace
  export INPUT_EXCLUDE="alpha" INPUT_DRY_RUN=true
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value crate_name)" = "zeta mid" ]
  [ "$(head -n 1 "$MOCK_CARGO_SETS")" = "package zeta mid" ]
}

@test "exclude warns about a name the workspace does not hold" {
  standard_workspace
  export INPUT_EXCLUDE="nonesuch" INPUT_DRY_RUN=true
  run_action

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::exclude names nonesuch, which is not a member of this workspace"* ]]
}

@test "packages selects the named members, ordered by their dependencies" {
  standard_workspace
  export INPUT_WORKSPACE=false INPUT_PACKAGES=$'alpha\n  mid' INPUT_DRY_RUN=true
  run_action

  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_CARGO_SETS")" = "$(printf '%s\n' 'package mid alpha' \
    'dry-run mid alpha' 'repackage mid alpha')" ]
  [ "$(output_value crate_name)" = "mid alpha" ]
  [ "$(output_value publish_status)" = dry-run ]
}

@test "packages replaces workspace" {
  standard_workspace
  export INPUT_PACKAGES="mid zeta" INPUT_DRY_RUN=true
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value crate_name)" = "zeta mid" ]
}

@test "one selected crate takes the single-crate path with its manifest" {
  standard_workspace
  export INPUT_PACKAGES=mid MOCK_EXPECT_PACKAGE_MANIFEST="$project/crates/mid/Cargo.toml"
  run_action

  [ "$status" -eq 0 ]
  assert_calls "$publish_calls"
  [ ! -s "$MOCK_CARGO_SETS" ]
  [ "$(cat "$GITHUB_OUTPUT")" = "$(printf '%s\n' cargo_version=1.98.1 \
    crate_name=mid crate_version=1.0.0 crate_size_bytes=32 \
    "crate_sha256=$(zero_sha256 32)" registry_status=absent \
    published=true publish_status=published)" ]
  grep -Fq '| Manifest | <code>member crate/crates/mid/Cargo.toml</code> |' \
    "$GITHUB_STEP_SUMMARY"
}

@test "a workspace with one crates.io member publishes it as a single crate" {
  make_workspace solo:2.0.0: hidden:1.0.0::false
  export INPUT_WORKSPACE=true MOCK_EXPECT_PACKAGE_MANIFEST="$project/crates/solo/Cargo.toml"
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value crate_name)" = solo ]
  [ "$(output_value crate_sha256)" = "$(zero_sha256 32)" ]
}

@test "packages must name workspace members crates.io accepts" {
  standard_workspace
  local name
  for name in nonesuch internal private; do
    export INPUT_PACKAGES="zeta $name"
    reset_logs
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::packages names $name, "* ]]
    assert_calls $'version\nmetadata'
  done
}

@test "fails when the workspace holds nothing for crates.io" {
  make_workspace internal:1.0.0::false private:1.0.0::other
  export INPUT_WORKSPACE=true
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"the selection holds no crate that can be published to crates.io"* ]]
}

@test "rejects invalid selection inputs before running cargo" {
  local -a cases=(
    "INPUT_WORKSPACE=yes|workspace must be 'true' or 'false'"
    "INPUT_PACKAGES=a,b|packages must list crate names"
    "INPUT_PACKAGES=a\$(id)|packages must list crate names"
    "INPUT_EXCLUDE=a/b|exclude must list crate names"
    "INPUT_EXCLUDE=a|exclude needs workspace set to 'true'"
  )
  local entry
  for entry in "${cases[@]}"; do
    unset INPUT_WORKSPACE INPUT_PACKAGES INPUT_EXCLUDE
    export "${entry%%|*}"
    reset_logs
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::${entry#*|}"* ]]
    assert_no_cargo
  done
  export INPUT_WORKSPACE=true INPUT_PACKAGES=a INPUT_EXCLUDE=b
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::exclude cannot be combined with packages"* ]]
}

@test "publishing a set needs Cargo 1.90; one crate does not" {
  standard_workspace
  export MOCK_CARGO_VERSION=1.89.0
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"publishing several crates needs Cargo 1.90 or later"* ]]
  assert_calls $'version\nmetadata'

  export INPUT_PACKAGES=zeta MOCK_EXPECT_PACKAGE_MANIFEST="$project/crates/zeta/Cargo.toml"
  unset INPUT_WORKSPACE
  reset_logs
  run_action
  [ "$status" -eq 0 ]
}

@test "release_tag must match every selected crate" {
  make_workspace a:1.0.0: b:1.1.0:a
  export INPUT_WORKSPACE=true INPUT_RELEASE_TAG=v1.0.0
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"b Cargo.toml version (1.1.0) does not match release tag (1.0.0)"* ]]
  assert_calls $'version\nmetadata'

  make_workspace a:1.1.0: b:1.1.0:a
  export INPUT_RELEASE_TAG=1.1.0 INPUT_DRY_RUN=true
  reset_logs
  run_action
  [ "$status" -eq 0 ]
  grep -Fq '| Release tag | ✅ <code>1.1.0</code> matches all 2 crates |' \
    "$GITHUB_STEP_SUMMARY"
}

@test "enforces the size limit on every crate of a set" {
  standard_workspace
  export INPUT_MAX_CRATE_SIZE_BYTES=36
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"alpha package is 37 bytes, exceeding the 36-byte limit"* ]]
  assert_calls $'version\nmetadata\npackage'
}

@test "refuses a set whose member changed after verification" {
  standard_workspace
  export MOCK_TAMPER=mid
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"mid package changed after verification; not publishing"* ]]
  assert_calls "$dry_run_calls"
}

@test "fails when Cargo leaves out a member's archive" {
  standard_workspace
  export MOCK_MISSING_PACKAGE=mid
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"cargo package did not produce mid-1.0.0.crate"* ]]
}

### Workspace digests ###

@test "a set's crate_sha256 map feeds expected_sha256 in a later run" {
  standard_workspace
  export INPUT_DRY_RUN=true
  run_action
  [ "$status" -eq 0 ]

  INPUT_EXPECTED_SHA256="$(output_value crate_sha256)"
  export INPUT_EXPECTED_SHA256 INPUT_DRY_RUN=false
  reset_logs
  run_action

  [ "$status" -eq 0 ]
  assert_calls $'version\nmetadata\nrepackage\ndry-run\nrepackage\npublish'
  [ "$(output_value crate_sha256)" = "$INPUT_EXPECTED_SHA256" ]
  grep -Fq 'Matches the digests from an earlier job; not compiled here' \
    "$GITHUB_STEP_SUMMARY"
}

@test "expected_sha256 accepts a map in any key order and layout" {
  standard_workspace
  INPUT_EXPECTED_SHA256="$(jq -n --argjson m "$(digest_map alpha zeta mid)" '$m')"
  export INPUT_EXPECTED_SHA256
  [[ "$INPUT_EXPECTED_SHA256" == *$'\n'* ]]
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value published)" = true ]
}

@test "expected_sha256 refuses a set with one differing archive" {
  standard_workspace
  INPUT_EXPECTED_SHA256="$(digest_map zeta mid alpha | jq -c --arg d "$(zero_sha256 1)" '.mid = $d')"
  export INPUT_EXPECTED_SHA256
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"mid package does not match its expected_sha256 entry"* ]]
  assert_calls $'version\nmetadata\nrepackage'
}

@test "rejects malformed digest maps before running cargo" {
  local digest map
  digest="$(zero_sha256 1)"
  for map in '{' '{}' '[]' '{"a":1}' '{"a":"ABC"}' "{\"a\":\"${digest^^}\"}" \
    "{\"a b\":\"$digest\"}" "{\"a\":{\"b\":\"$digest\"}}" \
    "{\"a\":\"$digest\",\"a\":\"$digest\"}" \
    "{\"a\":\"$digest\"} {\"b\":\"$digest\"}"; do
    export INPUT_EXPECTED_SHA256="$map"
    reset_logs
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::expected_sha256 must be "* ]]
    assert_no_cargo
  done
}

@test "a digest map without jq on PATH names the missing tool" {
  local tool saved_path="$PATH"
  mkdir -p "$workdir/no-jq"
  for tool in wc dirname env; do
    ln -s "$(command -v "$tool")" "$workdir/no-jq/$tool"
  done
  INPUT_EXPECTED_SHA256="$(digest_map example-crate)"
  export INPUT_EXPECTED_SHA256
  export PATH="$workdir/no-jq"
  run_action
  export PATH="$saved_path"

  [ "$status" -eq 1 ]
  [[ "$output" == *"required tool not found on PATH: jq"* ]]
}

@test "a digest map must name exactly the selected crates" {
  standard_workspace
  local map
  for map in "$(digest_map zeta mid)" "$(digest_map zeta mid alpha internal)"; do
    export INPUT_EXPECTED_SHA256="$map"
    reset_logs
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"expected_sha256 must name exactly the selected crates: zeta mid alpha"* ]]
    assert_calls $'version\nmetadata'
  done
}

@test "a single digest cannot cover several crates" {
  standard_workspace
  INPUT_EXPECTED_SHA256="$(zero_sha256 32)"
  export INPUT_EXPECTED_SHA256
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"expected_sha256 holds one digest, but 3 crates are selected"* ]]
  assert_calls $'version\nmetadata'
}

@test "a one-entry digest map works for a single crate" {
  INPUT_EXPECTED_SHA256="$(jq -cn --arg d "$(zero_sha256 32)" '{"example-crate": $d}')"
  export INPUT_EXPECTED_SHA256
  run_action

  [ "$status" -eq 0 ]
  assert_calls $'version\nmetadata\nrepackage\ndry-run\nrepackage\npublish'
  [ "$(output_value crate_sha256)" = "$(zero_sha256 32)" ]

  INPUT_EXPECTED_SHA256="$(jq -cn --arg d "$(zero_sha256 32)" '{"other-crate": $d}')"
  reset_logs
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"expected_sha256 must name exactly the selected crates: example-crate"* ]]
  assert_calls $'version\nmetadata'
}

### Workspace re-runs and partial failure ###

@test "a re-run skips members already published and uploads the rest" {
  standard_workspace
  published_entry zeta "$(set_sha256 zeta)"
  run_action

  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_CARGO_SETS")" = "$(printf '%s\n' \
    'package zeta mid alpha' 'dry-run mid alpha' \
    'repackage zeta mid alpha' 'publish mid alpha')" ]
  [ "$(output_value registry_status)" = \
    '{"zeta":"identical","mid":"absent","alpha":"absent"}' ]
  [ "$(output_value publish_status)" = published ]
  grep -Fq '| <code>zeta 1.0.0</code> | ⛔️ Skipped: identical archive already on crates.io;' \
    "$GITHUB_STEP_SUMMARY"
}

@test "a set already published in full is skipped without an upload" {
  standard_workspace
  local name
  for name in zeta mid alpha; do
    published_entry "$name" "$(set_sha256 "$name")"
  done
  run_action

  [ "$status" -eq 0 ]
  assert_calls $'version\nmetadata\npackage'
  [ "$(output_value published)" = false ]
  [ "$(output_value publish_status)" = skipped ]
  grep -Fq '### ⛔️ Skipped: previously published: 3 crates' "$GITHUB_STEP_SUMMARY"
}

@test "one member with different published content stops the release" {
  standard_workspace
  published_entry mid "$(zero_sha256 1)"
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"mid 1.0.0 is already on crates.io with different content"* ]]
  assert_calls $'version\nmetadata\npackage'
  [ "$(output_value registry_status)" = '{"zeta":"absent","mid":"different"}' ]

  export INPUT_DRY_RUN=true
  reset_logs
  run_action
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::mid 1.0.0 is already on crates.io with different content"* ]]
}

@test "a failed upload records what reached crates.io, and a re-run resumes" {
  standard_workspace
  export MOCK_PUBLISH_FAIL_AT=alpha
  run_action

  [ "$status" -eq 43 ]
  [ "$(output_value published)" = true ]
  [ "$(output_value publish_status)" = failed ]
  [ "$(last_output_value registry_status)" = \
    '{"zeta":"identical","mid":"identical","alpha":"absent"}' ]
  [[ "$output" == *"after uploading 2 of 3 crates. A re-run skips the uploaded ones and resumes."* ]]
  grep -Fq '| <code>mid 1.0.0</code> | 🚀 Published;' "$GITHUB_STEP_SUMMARY"
  grep -Fq '| <code>alpha 1.0.0</code> | ❌ Not published;' "$GITHUB_STEP_SUMMARY"

  unset MOCK_PUBLISH_FAIL_AT
  reset_logs
  run_action

  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$MOCK_CARGO_SETS")" = "publish alpha" ]
  [ "$(output_value registry_status)" = \
    '{"zeta":"identical","mid":"identical","alpha":"absent"}' ]
  [ "$(output_value publish_status)" = published ]
}

@test "a failed upload reports other content that reached crates.io first" {
  standard_workspace
  MOCK_RACE_CKSUM="$(zero_sha256 1)"
  export MOCK_PUBLISH_FAIL_AT=alpha MOCK_RACE_CKSUM
  run_action

  [ "$status" -eq 43 ]
  [ "$(last_output_value registry_status)" = \
    '{"zeta":"identical","mid":"identical","alpha":"different"}' ]
  [[ "$output" == *"after uploading 2 of 3 crates."* ]]
  grep -Fq '| <code>alpha 1.0.0</code> | ❌ Not published; 37 B; ⚠️ crates.io holds different content;' \
    "$GITHUB_STEP_SUMMARY"
}

@test "permit_fail covers a failed set upload" {
  standard_workspace
  export MOCK_PUBLISH_FAIL_AT=zeta INPUT_PERMIT_FAIL=true
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value publish_status)" = failed ]
  [ "$(output_value published)" = false ]
}

@test "only the set upload sees registry_token" {
  standard_workspace
  export INPUT_REGISTRY_TOKEN=secret-token CARGO_REGISTRY_TOKEN=ambient
  run_action

  [ "$status" -eq 0 ]
  [ "$(stage_env publish 3)" = secret-token ]
  local stage
  for stage in version metadata package dry-run repackage; do
    [ "$(stage_env "$stage" 3)" = unset ]
  done
  [[ "$output" == *"Trusted Publisher config surface for zeta mid alpha"* ]]
}

### Workspace on a named registry ###

# The staging index URL of a crate, as lookup_registry builds it.
staging_entry() {
  printf 'https://index.staging.example/%s\n' "$@"
}

@test "a set on a named registry passes --registry to every Cargo call" {
  use_staging
  standard_workspace
  run_action

  [ "$status" -eq 0 ]
  # The cargo stand-in rejects any call without '--registry staging'.
  assert_calls "$publish_calls"
  [ "$(cat "$MOCK_CARGO_SETS")" = "$(printf '%s\n' \
    'package zeta mid alpha' 'dry-run zeta mid alpha' \
    'repackage zeta mid alpha' 'publish zeta mid alpha')" ]
  [ "$(cat "$MOCK_CURL_LOG")" = "$(staging_entry config.json \
    ze/ta/zeta 3/m/mid al/ph/alpha)" ]
  [ "$(output_value registry_status)" = \
    '{"zeta":"absent","mid":"absent","alpha":"absent"}' ]
  [[ "$output" == *"Published 3 crates to staging registry"* ]]
}

@test "a digest map packages a set for the named registry too" {
  use_staging
  standard_workspace
  INPUT_EXPECTED_SHA256="$(digest_map zeta mid alpha)"
  export INPUT_EXPECTED_SHA256
  run_action

  [ "$status" -eq 0 ]
  assert_calls $'version\nmetadata\nrepackage\ndry-run\nrepackage\npublish'
  [ "$(head -n 1 "$MOCK_CARGO_SETS")" = "repackage zeta mid alpha" ]
}

@test "a set's upload gets registry_token under the named registry alone" {
  use_staging
  standard_workspace
  export INPUT_REGISTRY_TOKEN=input-token CARGO_REGISTRY_TOKEN=crates-io-token
  run_action

  [ "$status" -eq 0 ]
  local stage
  for stage in version metadata package dry-run repackage; do
    [ "$(stage_vars "$stage")" = "$staging_vars" ]
  done
  [ "$(stage_vars publish)" = "CARGO_REGISTRIES_STAGING_CREDENTIAL_PROVIDER=cargo:token ${staging_vars}CARGO_REGISTRIES_STAGING_TOKEN=input-token CARGO_REGISTRY_GLOBAL_CREDENTIAL_PROVIDERS=cargo:token " ]
}

@test "a set's upload keeps the caller's token for the named registry alone" {
  use_staging
  standard_workspace
  export_scrubbed_variables
  export CARGO_REGISTRIES_STAGING_TOKEN=staging-token
  run_action

  [ "$status" -eq 0 ]
  local stage
  local kept="CARGO_REGISTRIES_PRIVATE_INDEX=sparse+https://private.example/ $staging_vars"
  for stage in version metadata package dry-run repackage; do
    [ "$(stage_vars "$stage")" = "$kept" ]
  done
  [ "$(stage_vars publish)" = "${kept}CARGO_REGISTRIES_STAGING_TOKEN=staging-token " ]
}

# Measured on cargo 1.99: metadata reports each package.publish list
# verbatim, and Cargo matches the --registry name against it exactly.
@test "a set keeps the members whose publish list names the registry" {
  make_workspace a:1.0.0::staging b:1.0.0::crates-io c:1.0.0: \
    d:1.0.0::false e:1.0.0::crates-io,staging f:1.0.0::Staging
  export INPUT_WORKSPACE=true INPUT_DRY_RUN=true
  use_staging
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value crate_name)" = "a c e" ]
  [[ "$output" == *"::notice::Skipping workspace members whose package.publish setting excludes staging registry: b, d, f"* ]]

  unset INPUT_REGISTRY MOCK_EXPECT_REGISTRY
  reset_logs
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value crate_name)" = "b c e" ]
  [[ "$output" == *"excludes crates.io: a, d, f"* ]]
}

@test "packages refuses a member whose publish list omits the registry" {
  make_workspace a:1.0.0::staging b:1.0.0::crates-io
  export INPUT_PACKAGES="a b"
  use_staging
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"packages names b, whose package.publish setting excludes staging registry"* ]]
  assert_calls $'version\nmetadata'
}

@test "a hyphenated registry name must match the publish list exactly" {
  make_workspace a:1.0.0::my-registry b:1.0.0::my_registry c:1.0.0:
  export INPUT_WORKSPACE=true INPUT_DRY_RUN=true
  export INPUT_REGISTRY=my-registry MOCK_EXPECT_REGISTRY=my-registry
  export CARGO_REGISTRIES_MY_REGISTRY_INDEX="$staging_index"
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value crate_name)" = "a c" ]
  [[ "$output" == *"excludes my-registry registry: b"* ]]
}

@test "a failed set upload re-checks the named registry's index" {
  use_staging
  standard_workspace
  export MOCK_PUBLISH_FAIL_AT=alpha
  run_action

  [ "$status" -eq 43 ]
  [ "$(output_value published)" = true ]
  [ "$(last_output_value registry_status)" = \
    '{"zeta":"identical","mid":"identical","alpha":"absent"}' ]
  [ "$(cat "$MOCK_CURL_LOG")" = "$(staging_entry config.json \
    ze/ta/zeta 3/m/mid al/ph/alpha ze/ta/zeta 3/m/mid al/ph/alpha)" ]
  grep -Fq '| <code>mid 1.0.0</code> | 🚀 Published;' "$GITHUB_STEP_SUMMARY"
  run ! grep -q 'https://crates.io/crates/' "$GITHUB_STEP_SUMMARY"

  unset MOCK_PUBLISH_FAIL_AT
  reset_logs
  run_action

  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$MOCK_CARGO_SETS")" = "publish alpha" ]
  [[ "$output" == *"zeta 1.0.0 is already on staging registry with identical content; skipping its upload"* ]]
  grep -Fq '| <code>zeta 1.0.0</code> | ⛔️ Skipped: identical archive already on staging registry;' \
    "$GITHUB_STEP_SUMMARY"
}

@test "a named registry may answer 410 or 451 for absent set members" {
  local code
  for code in 410 451; do
    use_staging
    standard_workspace
    export MOCK_INDEX_DIR_MISSING="$code" INPUT_DRY_RUN=true
    reset_logs
    run_action

    [ "$status" -eq 0 ]
    [ "$(output_value registry_status)" = \
      '{"zeta":"absent","mid":"absent","alpha":"absent"}' ]

    unset INPUT_REGISTRY MOCK_EXPECT_REGISTRY
    reset_logs
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"the crates.io index answered HTTP $code for zeta"* ]]
  done
}

@test "different content on a named registry fails a set release" {
  use_staging
  standard_workspace
  published_entry mid "$(zero_sha256 1)"
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"mid 1.0.0 is already on staging registry with different content"* ]]
  [[ "$output" == *"Cargo will not publish a version the registry already holds"* ]]
  assert_calls $'version\nmetadata\npackage'
}

### Workspace job summary ###

@test "a set's summary has one row per crate" {
  standard_workspace
  export INPUT_DRY_RUN=true
  run_action

  [ "$status" -eq 0 ]
  grep -Fq '### ✅ Dry run passed: 3 crates' "$GITHUB_STEP_SUMMARY"
  grep -Fq '| Not publishable | internal, private |' "$GITHUB_STEP_SUMMARY"
  grep -Fqx "| <code>zeta 1.0.0</code> | ✅ Dry run passed; 36 B; not yet on crates.io; <code>$(set_sha256 zeta)</code> |" \
    "$GITHUB_STEP_SUMMARY"
  [ "$(grep -c '^| <code>' "$GITHUB_STEP_SUMMARY")" -eq 3 ]
  run ! grep -q '| Package size |' "$GITHUB_STEP_SUMMARY"
}

@test "a dry run row notes an identical archive already on crates.io" {
  standard_workspace
  published_entry zeta "$(set_sha256 zeta)"
  export INPUT_DRY_RUN=true
  run_action

  [ "$status" -eq 0 ]
  grep -Fqx "| <code>zeta 1.0.0</code> | ✅ Dry run passed; 36 B; already on crates.io, identical archive; <code>$(set_sha256 zeta)</code> |" \
    "$GITHUB_STEP_SUMMARY"
}

@test "a published set links every crate" {
  standard_workspace
  run_action

  [ "$status" -eq 0 ]
  grep -Fq '### 🚀 Published: 3 crates' "$GITHUB_STEP_SUMMARY"
  grep -Fqx "| <code>alpha 1.0.0</code> | 🚀 Published; 37 B; <code>$(set_sha256 alpha)</code>; 🔗 https://crates.io/crates/alpha/1.0.0 |" \
    "$GITHUB_STEP_SUMMARY"
}

### Action wiring ###

@test "action.yaml runs the script and passes exactly the inputs it reads" {
  local declared passed consumed
  # shellcheck disable=SC2016 # the literal line from action.yaml
  grep -Fqx '      run: bash "$ACTION_PATH/scripts/publish-crate.sh"' \
    "$action_file"
  declared="$(sed -n '/^inputs:/,/^outputs:/s/^  \([a-z0-9_]*\):$/\1/p' \
    "$action_file" | tr '[:lower:]' '[:upper:]' | sed 's/^/INPUT_/' | sort)"
  passed="$(sed -n 's/^ *\(INPUT_[A-Z0-9_]*\): .*/\1/p' "$action_file" | sort)"
  consumed="$(grep -ho 'INPUT_[A-Z][A-Z0-9_]*' "$script" \
    "$repo_dir/scripts/workspace.sh" | sort -u)"
  [ "$declared" = "$passed" ]
  [ "$passed" = "$consumed" ]
}

@test "action.yaml exposes the outputs the script writes" {
  local declared written
  declared="$(sed -n '/^outputs:/,/^runs:/s/^  \([a-z0-9_]*\):$/\1/p' \
    "$action_file" | sort)"
  written="$(grep -ho 'write_output [a-z0-9_]*' "$script" \
    "$repo_dir/scripts/workspace.sh" \
    | awk '$2 != "" { print $2 }' | sort -u)"
  [ "$declared" = "$written" ]
  [ "$(grep -c 'steps.publish.outputs.' "$action_file")" -eq "$(printf '%s\n' "$declared" | wc -l)" ]
}
