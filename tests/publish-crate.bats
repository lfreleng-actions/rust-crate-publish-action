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
  unset GITHUB_REPOSITORY GITHUB_WORKFLOW_REF RUSTUP_TOOLCHAIN
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
    "$MOCK_CURL_LOG" "$MOCK_CARGO_VARS" "$MOCK_RUSTUP_VARS"; do
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

### Action wiring ###

@test "action.yaml runs the script and passes exactly the inputs it reads" {
  local declared passed consumed
  # shellcheck disable=SC2016 # the literal line from action.yaml
  grep -Fqx '      run: bash "$ACTION_PATH/scripts/publish-crate.sh"' \
    "$action_file"
  declared="$(sed -n '/^inputs:/,/^outputs:/s/^  \([a-z0-9_]*\):$/\1/p' \
    "$action_file" | tr '[:lower:]' '[:upper:]' | sed 's/^/INPUT_/' | sort)"
  passed="$(sed -n 's/^ *\(INPUT_[A-Z0-9_]*\): .*/\1/p' "$action_file" | sort)"
  consumed="$(grep -o 'INPUT_[A-Z][A-Z0-9_]*' "$script" | sort -u)"
  [ "$declared" = "$passed" ]
  [ "$passed" = "$consumed" ]
}

@test "action.yaml exposes the outputs the script writes" {
  local declared written
  declared="$(sed -n '/^outputs:/,/^runs:/s/^  \([a-z0-9_]*\):$/\1/p' \
    "$action_file" | sort)"
  written="$(grep -o 'write_output [a-z0-9_]*' "$script" \
    | awk '$2 != "" { print $2 }' | sort -u)"
  [ "$declared" = "$written" ]
  [ "$(grep -c 'steps.publish.outputs.' "$action_file")" -eq "$(printf '%s\n' "$declared" | wc -l)" ]
}
