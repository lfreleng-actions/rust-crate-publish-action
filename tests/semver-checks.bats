#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Tests for the opt-in semver stage (scripts/semver-checks.sh), driven
# through scripts/publish-crate.sh against the stand-ins in fixtures/:
# cargo, rustup, curl and cargo-semver-checks. Nothing here compiles,
# publishes or reaches the network.

# Exports in one @test stay in that test's subshell.
# shellcheck disable=SC2030,SC2031

bats_require_minimum_version 1.7.0

setup() {
  local root tool file name
  root="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  publish_script="$root/scripts/publish-crate.sh"
  semver_script="$root/scripts/semver-checks.sh"
  mkdir -p "$BATS_TEST_TMPDIR/ws root"
  tmp="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  ws="$tmp/ws root"
  crate_dir="$ws/the crate"
  stand_ins="$ws/stand-ins"
  mkdir -p "$crate_dir" "$stand_ins" "$tmp/cargo home" "$ws/tmp"
  for tool in cargo rustup curl cargo-semver-checks; do
    cp "$BATS_TEST_DIRNAME/fixtures/$tool.sh" "$stand_ins/$tool"
    chmod +x "$stand_ins/$tool"
  done
  cp "$BATS_TEST_DIRNAME/fixtures/Cargo.toml" "$crate_dir/Cargo.toml"
  cp "$BATS_TEST_DIRNAME/fixtures/manifest.json" "$ws/manifest.json"

  # Clear anything the calling environment could leak into a test.
  unset INPUT_MANIFEST_PATH INPUT_RELEASE_TAG INPUT_MAX_CRATE_SIZE_BYTES
  unset INPUT_PERMIT_FAIL INPUT_SUMMARY INPUT_REGISTRY_TOKEN
  unset INPUT_EXPECTED_SHA256 INPUT_CARGO_SEMVER_CHECKS_VERSION
  unset ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL
  unset ACTIONS_RUNTIME_TOKEN GITHUB_ENV GITHUB_PATH GITHUB_STATE
  unset CARGO_TARGET_DIR RUSTUP_TOOLCHAIN MOCK_TOOLCHAIN MOCK_FAIL_STAGE
  unset MOCK_INDEX_STATUS MOCK_INDEX_BODY MOCK_INDEX_STATUS_2
  unset MOCK_INDEX_BODY_2 MOCK_CURL_FAIL MOCK_SEMVER_STATUS
  unset MOCK_SEMVER_VERSION MOCK_SEMVER_VERSION_FAIL
  unset INPUT_REGISTRY MOCK_EXPECT_REGISTRY MOCK_CONFIG_STATUS
  unset MOCK_CONFIG_BODY MOCK_DRY_RUN_EXISTS
  unset INPUT_WORKSPACE INPUT_PACKAGES INPUT_EXCLUDE MOCK_WORKSPACE_JSON
  unset MOCK_EXPECT_PACKAGE_MANIFEST MOCK_INDEX_DIR MOCK_CARGO_SETS
  unset MOCK_INDEX_DIR_MISSING MOCK_SEMVER_CALLS MOCK_SEMVER_FAIL_PACKAGE
  # Any host registry token would trip the credential refusal, and other
  # registry settings would reach the stand-ins.
  for name in $(compgen -e); do
    case "$name" in
      CARGO_REGISTRY_* | CARGO_REGISTRIES_*) unset "$name" ;;
    esac
  done

  export PATH="$stand_ins:$PATH"
  export GITHUB_WORKSPACE="$ws"
  export GITHUB_OUTPUT="$ws/outputs"
  export GITHUB_STEP_SUMMARY="$ws/summary"
  export RUNNER_TEMP="$ws/tmp"
  export CARGO_HOME="$tmp/cargo home"
  export INPUT_PATH_PREFIX="the crate"
  export INPUT_DRY_RUN=true
  export INPUT_SEMVER_CHECKS=true
  export MOCK_EXPECT_MANIFEST="$crate_dir/Cargo.toml"
  export MOCK_MANIFEST_JSON="$ws/manifest.json"
  export MOCK_CRATE_SIZE=64
  export MOCK_CARGO_LOG="$ws/cargo.log"
  export MOCK_CARGO_ENV="$ws/cargo.env"
  export MOCK_CARGO_VARS="$ws/cargo.vars"
  export MOCK_CARGO_TARGETS="$ws/cargo.targets"
  export MOCK_RUSTUP_LOG="$ws/rustup.log"
  export MOCK_RUSTUP_VARS="$ws/rustup.vars"
  export MOCK_CURL_LOG="$ws/curl.log"
  export MOCK_SEMVER_ARGS="$ws/semver.args"
  export MOCK_SEMVER_ENV="$ws/semver.env"
  for file in "$GITHUB_OUTPUT" "$GITHUB_STEP_SUMMARY" "$MOCK_CARGO_LOG" \
    "$MOCK_CARGO_ENV" "$MOCK_CARGO_TARGETS" "$MOCK_RUSTUP_LOG" \
    "$MOCK_CURL_LOG" "$MOCK_CARGO_VARS" "$MOCK_RUSTUP_VARS"; do
    : > "$file"
  done
}

publish() {
  run "$BASH" "$publish_script"
}

# Serve these crates.io index lines, one JSON object per argument
# pair: version and yanked flag. The checksum never matches ours.
serve_index() {
  local body="$ws/index.json"
  : > "$body"
  while [ "$#" -gt 1 ]; do
    printf '{"name":"example-crate","vers":"%s","cksum":"%064d","yanked":%s}\n' \
      "$1" 0 "$2" >> "$body"
    shift 2
  done
  export MOCK_INDEX_STATUS=200 MOCK_INDEX_BODY="$body"
}

step_output() {
  sed -n "s/^$1=//p" "$GITHUB_OUTPUT"
}

semver_row() {
  grep '^| Semver |' "$GITHUB_STEP_SUMMARY"
}

semver_env() {
  grep -x -- "$1" "$MOCK_SEMVER_ENV"
}

expect_refusal() {
  publish
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::semver_checks compiles the crate"*"this run $1"* ]]
  [ ! -s "$MOCK_CARGO_LOG" ]
  [ ! -e "$MOCK_SEMVER_ARGS" ]
  [ "$(step_output publish_status)" = failed ]
  [ -z "$(step_output semver_status)" ]
}

### Disabled by default ###

@test "default inputs leave the run unchanged and need no tool" {
  unset INPUT_SEMVER_CHECKS
  rm "$stand_ins/cargo-semver-checks"
  serve_index 1.2.0 false

  publish

  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_CARGO_LOG")" = $'version\nmetadata\npackage\ndry-run\nrepackage' ]
  [ "$(wc -l < "$MOCK_CURL_LOG")" -eq 1 ]
  [ ! -e "$MOCK_SEMVER_ARGS" ]
  [ "$(grep -c '^semver' "$GITHUB_OUTPUT")" -eq 0 ]
  [ "$(grep -c 'Semver' "$GITHUB_STEP_SUMMARY")" -eq 0 ]
}

@test "semver_checks 'false' does not run the check" {
  export INPUT_SEMVER_CHECKS=false
  serve_index 1.2.0 false

  publish

  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_SEMVER_ARGS" ]
  [ "$(grep -c 'semver-checks' "$MOCK_CARGO_LOG")" -eq 0 ]
}

# action.yaml skips its version check and install unless semver_checks
# is 'true', so the unused input must not fail the run either.
@test "cargo_semver_checks_version is ignored while semver_checks is 'false'" {
  export INPUT_SEMVER_CHECKS=false INPUT_CARGO_SEMVER_CHECKS_VERSION=latest

  publish

  [ "$status" -eq 0 ]
  [[ "$output" != *"cargo_semver_checks_version"* ]]
  [ "$(step_output publish_status)" = dry-run ]
}

### Input validation ###

@test "semver_checks accepts only 'true' or 'false', even with permit_fail" {
  export INPUT_SEMVER_CHECKS=yes INPUT_PERMIT_FAIL=true

  publish

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::semver_checks must be 'true' or 'false'"* ]]
  [ ! -s "$MOCK_CARGO_LOG" ]
}

@test "cargo_semver_checks_version must be a release version" {
  local bad
  for bad in "" "latest" "0.51" "v0.51.0" "0.51.0,cargo-deny" \
    "0.51.0 cargo-deny" $'0.51.0\n::warning::x'; do
    export INPUT_CARGO_SEMVER_CHECKS_VERSION="$bad"
    : > "$GITHUB_OUTPUT"
    publish
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::cargo_semver_checks_version must be a release version"* ]]
    [[ "$output" != *"::warning::x"* ]]
    [ ! -s "$MOCK_CARGO_LOG" ]
  done
}

@test "run directly, the script checks the version alone" {
  run "$BASH" "$semver_script" 0.51.0
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run "$BASH" "$semver_script" "0.51.0 cargo-deny"
  [ "$status" -eq 1 ]
  [ "$output" = "::error::cargo_semver_checks_version must be a release version such as 0.51.0" ]

  run "$BASH" "$semver_script"
  [ "$status" -eq 1 ]
  [ "$output" = "::error::cargo_semver_checks_version must be a release version such as 0.51.0" ]
}

@test "a missing cargo-semver-checks fails before any cargo call" {
  rm "$stand_ins/cargo-semver-checks"
  export INPUT_PERMIT_FAIL=true

  publish

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::required tool not found on PATH: cargo-semver-checks"* ]]
  [ ! -s "$MOCK_CARGO_LOG" ]
}

### Refused wherever publishing credentials are in reach ###

@test "refuses a publishing run (dry_run 'false')" {
  export INPUT_DRY_RUN=false
  expect_refusal "publishes (dry_run is 'false')"
}

@test "refuses a run given expected_sha256" {
  export INPUT_EXPECTED_SHA256
  INPUT_EXPECTED_SHA256="$(printf '%064d' 7)"
  expect_refusal "is a publishing job (expected_sha256 is set)"
}

@test "refuses a run given registry_token, without echoing it" {
  export INPUT_REGISTRY_TOKEN=cio-secret-value
  expect_refusal "holds registry_token"
  [[ "$(grep '::error::' <<< "$output")" != *cio-secret-value* ]]
  [[ "$(cat "$GITHUB_STEP_SUMMARY")" != *"cio-secret-value"* ]]
}

@test "refuses a run with a registry token in the environment" {
  local name
  for name in CARGO_REGISTRY_TOKEN CARGO_REGISTRIES_CRATES_IO_TOKEN \
    CARGO_REGISTRIES_PRIVATE_TOKEN; do
    : > "$GITHUB_OUTPUT"
    export "$name=env-secret-value"
    expect_refusal "has $name set"
    [[ "$output" != *"env-secret-value"* ]]
    unset "$name"
  done
}

@test "refuses a run that can mint an OIDC token (id-token: write)" {
  local name
  for name in ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL; do
    : > "$GITHUB_OUTPUT"
    export "$name=oidc-value"
    expect_refusal "has $name set"
    unset "$name"
  done
}

@test "refuses a run with a Cargo credentials file" {
  local file
  for file in credentials.toml credentials; do
    : > "$GITHUB_OUTPUT"
    : > "$CARGO_HOME/$file"
    expect_refusal "has a Cargo credentials file in CARGO_HOME"
    rm "$CARGO_HOME/$file"
  done
}

# Cargo resolves a relative CARGO_HOME against the directory it runs
# in, which for the Package stage is the crate's, not the action's.
@test "refuses a run with credentials under a relative CARGO_HOME" {
  export CARGO_HOME="../../rel home"
  mkdir -p "$tmp/rel home"
  : > "$tmp/rel home/credentials.toml"
  expect_refusal "has a Cargo credentials file in CARGO_HOME"
}

@test "passes a relative CARGO_HOME to the check as the path it checked" {
  serve_index 1.2.0 false
  export CARGO_HOME="../../rel home"

  publish

  [ "$status" -eq 0 ]
  [ "$(step_output semver_status)" = passed ]
  semver_env "CARGO_HOME=$tmp/rel home"
}

### Cargo home inside the workspace ###

# Source replacement in the Cargo home's config.toml could swap a
# forged baseline in for crates.io, so the home must not resolve into
# the checkout. The message names CARGO_HOME, never its value.
expect_home_refusal() {
  local permit
  for permit in false true; do
    : > "$GITHUB_OUTPUT"
    export INPUT_PERMIT_FAIL="$permit"
    publish
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::semver_checks needs CARGO_HOME to resolve outside the workspace"* ]]
    [[ "$output" != *"marker"* ]]
    [ ! -s "$MOCK_CARGO_LOG" ]
    [ ! -e "$MOCK_SEMVER_ARGS" ]
    [ "$(step_output publish_status)" = failed ]
  done
}

@test "refuses an absolute CARGO_HOME inside the workspace" {
  mkdir "$ws/home marker"
  export CARGO_HOME="$ws/home marker"
  expect_home_refusal
  export CARGO_HOME="$ws"
  expect_home_refusal
  export CARGO_HOME="$tmp/ws root/./the crate/../not yet marker"
  expect_home_refusal
}

@test "refuses a relative CARGO_HOME that resolves inside the workspace" {
  mkdir "$crate_dir/home marker"
  export CARGO_HOME="home marker"
  expect_home_refusal
  export CARGO_HOME="not yet marker/sub"
  expect_home_refusal
  export CARGO_HOME="../../ws root/home marker"
  expect_home_refusal
}

@test "refuses a CARGO_HOME that a symlink leads into the workspace" {
  mkdir "$ws/home marker"
  ln -s "$ws/home marker" "$tmp/link marker"
  export CARGO_HOME="$tmp/link marker"
  expect_home_refusal
  ln -s "$ws" "$tmp/dir link marker"
  export CARGO_HOME="$tmp/dir link marker/not yet"
  expect_home_refusal
  ln -s "$crate_dir" "$tmp/crate link marker"
  export CARGO_HOME="../../crate link marker/home marker"
  expect_home_refusal
}

@test "refuses a CARGO_HOME it cannot resolve" {
  ln -s "$tmp/missing" "$tmp/dangling marker"
  export CARGO_HOME="$tmp/dangling marker/sub"
  expect_home_refusal
  : > "$tmp/file marker"
  export CARGO_HOME="$tmp/file marker/sub"
  expect_home_refusal
}

@test "accepts a CARGO_HOME outside the workspace, as its physical path" {
  serve_index 1.2.0 false
  mkdir -p "$tmp/real home" "$tmp/ws root2"
  ln -s "$tmp/real home" "$ws/link to outside"
  # A sibling whose name extends the workspace's is still outside it.
  for home in "$ws/link to outside" "$tmp/ws root2" "$tmp/later/home"; do
    : > "$GITHUB_OUTPUT"
    export CARGO_HOME="$home"
    publish
    [ "$status" -eq 0 ]
    [ "$(step_output semver_status)" = passed ]
  done
  semver_env "CARGO_HOME=$tmp/later/home"
  export CARGO_HOME="$ws/link to outside"
  publish
  semver_env "CARGO_HOME=$tmp/real home"
}

@test "accepts an unset CARGO_HOME, using the default" {
  serve_index 1.2.0 false
  export HOME="$tmp/user home"
  for value in unset empty; do
    : > "$GITHUB_OUTPUT"
    if [ "$value" = unset ]; then unset CARGO_HOME; else export CARGO_HOME=""; fi
    publish
    [ "$status" -eq 0 ]
    [ "$(step_output semver_status)" = passed ]
    semver_env "CARGO_HOME=$tmp/user home/.cargo"
  done
}

@test "a CARGO_HOME inside the workspace is fine while semver_checks is 'false'" {
  export INPUT_SEMVER_CHECKS=false
  mkdir "$ws/home marker"
  export CARGO_HOME="$ws/home marker"
  serve_index 1.2.0 false
  publish
  [ "$status" -eq 0 ]
  [ "$(step_output publish_status)" != failed ]
  [ ! -e "$MOCK_SEMVER_ARGS" ]
}

@test "refusal ignores permit_fail" {
  export INPUT_PERMIT_FAIL=true ACTIONS_ID_TOKEN_REQUEST_URL=https://oidc.invalid
  expect_refusal "has ACTIONS_ID_TOKEN_REQUEST_URL set"
}

@test "credentials do not matter while semver_checks is 'false'" {
  export INPUT_SEMVER_CHECKS=false INPUT_DRY_RUN=false
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN=oidc-value
  publish
  [ "$status" -eq 0 ]
  [ "$(step_output publish_status)" = published ]
}

### Workspace members ###

# Describe workspace members named NAME:VERSION to the cargo stand-in.
workspace_members() {
  local spec name version entries="[]"
  for spec in "$@"; do
    IFS=: read -r name version <<< "$spec"
    mkdir -p "$crate_dir/crates/$name"
    : > "$crate_dir/crates/$name/Cargo.toml"
    entries="$(jq -c --arg n "$name" --arg v "$version" \
      --arg m "$crate_dir/crates/$name/Cargo.toml" '. + [{
        id: ("path+file://" + $m + "#" + $n + "@" + $v), name: $n,
        version: $v, manifest_path: $m, publish: null,
        dependencies: []}]' <<< "$entries")"
  done
  printf '%s\n' "$entries" > "$ws/workspace.json"
  export MOCK_WORKSPACE_JSON="$ws/workspace.json"
}

# Select the members as a set, logging Cargo's set stages and every
# check-release call, with an empty stand-in index.
workspace_set() {
  workspace_members "$@"
  mkdir -p "$ws/index"
  export INPUT_WORKSPACE=true MOCK_INDEX_DIR="$ws/index"
  export MOCK_CARGO_SETS="$ws/cargo.sets" MOCK_SEMVER_CALLS="$ws/semver.calls"
}

# Record NAME's crates.io index entries, one per VERSION:CKSUM pair.
member_index() {
  local name="$1" spec version cksum
  shift
  : > "$MOCK_INDEX_DIR/$name"
  for spec in "$@"; do
    IFS=: read -r version cksum <<< "$spec"
    printf '{"name":"%s","vers":"%s","cksum":"%s","yanked":false}\n' \
      "$name" "$version" "${cksum:-$(printf '%064d' 0)}" >> "$MOCK_INDEX_DIR/$name"
  done
}

# SHA-256 of the archive the cargo stand-in packages for NAME in a set.
member_sha256() {
  local sum
  if command -v sha256sum > /dev/null 2>&1; then
    sum="$({ printf '%s' "$1"; head -c "$MOCK_CRATE_SIZE" /dev/zero; } | sha256sum)"
  else
    sum="$({ printf '%s' "$1"; head -c "$MOCK_CRATE_SIZE" /dev/zero; } | shasum -a 256)"
  fi
  printf '%s\n' "${sum%% *}"
}

member_call() {
  printf '%s\n' "check-release --manifest-path $crate_dir/crates/$1/Cargo.toml --package $1 --baseline-version $2 --color never"
}

@test "checks each crate of a set against its own latest release" {
  workspace_set one:1.1.0 three:2.0.0 two:0.2.0
  member_index one 1.0.0 1.2.0 0.9.0
  member_index three "2.0.0:$(member_sha256 three)"

  publish

  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_SEMVER_CALLS")" = "$(member_call one 1.0.0)" ]
  [ "$(step_output semver_status)" = '{"one":"passed","three":"skipped","two":"skipped"}' ]
  [ "$(step_output semver_baseline)" = '{"one":"1.0.0"}' ]
  [ "$(step_output registry_status)" = '{"one":"absent","three":"identical","two":"absent"}' ]
  [[ "$output" == *"::notice::Semver check skipped for three 2.0.0: this exact archive is already on crates.io"* ]]
  [[ "$output" == *"::notice::Semver check skipped for two 0.2.0: crates.io holds no earlier release"* ]]
  [ "$(cat "$MOCK_CARGO_SETS")" = "$(printf '%s\n' 'package one three two' \
    'dry-run one three two' 'repackage one three two')" ]
  [ "$(step_output publish_status)" = dry-run ]
  [ "$(semver_row)" = "| Semver | <code>one</code>: ✅ Compatible with <code>1.0.0</code> (cargo-semver-checks 0.51.0); <code>three</code>: ➖ Skipped: identical archive already on crates.io; <code>two</code>: ➖ Skipped: no earlier release on crates.io |" ]
}

@test "a breaking change in one crate fails the set after checking all" {
  local permit
  workspace_set one:1.1.0 two:0.2.1
  member_index one 1.0.0
  member_index two 0.2.0
  export MOCK_SEMVER_FAIL_PACKAGE=one
  for permit in false true; do
    : > "$GITHUB_OUTPUT"
    : > "$MOCK_SEMVER_CALLS"
    : > "$MOCK_CARGO_SETS"
    export INPUT_PERMIT_FAIL="$permit"

    publish

    if [ "$permit" = true ]; then
      [ "$status" -eq 0 ]
      [[ "$output" == *"permit_fail is 'true'"* ]]
    else
      [ "$status" -eq 100 ]
    fi
    [ "$(cat "$MOCK_SEMVER_CALLS")" = "$(member_call one 1.0.0; member_call two 0.2.0)" ]
    [[ "$output" == *"::error::cargo-semver-checks found changes in one 1.1.0 that its version number does not allow, compared with 1.0.0"* ]]
    [ "$(step_output semver_status)" = '{"one":"failed","two":"passed"}' ]
    [ "$(step_output semver_baseline)" = '{"one":"1.0.0","two":"0.2.0"}' ]
    [ "$(step_output publish_status)" = failed ]
    [ "$(cat "$MOCK_CARGO_SETS")" = 'package one two' ]
    [[ "$(semver_row)" == *"<code>one</code>: ❌ Breaking changes against <code>1.0.0</code>: <code>function_missing</code>"* ]]
    [[ "$(semver_row)" == *"<code>two</code>: ✅ Compatible"* ]]
    if [ "$permit" = true ]; then
      grep -Fqx '### ⚠️ Failed at Check semver (permitted): 2 crates' "$GITHUB_STEP_SUMMARY"
    else
      grep -Fqx '### ❌ Failed at Check semver: 2 crates' "$GITHUB_STEP_SUMMARY"
    fi
    : > "$GITHUB_STEP_SUMMARY"
  done
}

@test "a tool that fails to start stops the set at its first check" {
  workspace_set one:1.1.0 two:0.2.1
  member_index one 1.0.0
  member_index two 0.2.0
  export MOCK_SEMVER_VERSION_FAIL=true

  publish

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::cargo-semver-checks --version failed"* ]]
  [ ! -s "$MOCK_SEMVER_CALLS" ]
  [ "$(step_output semver_status)" = '{"one":"failed"}' ]
  [ "$(step_output semver_baseline)" = '{"one":"1.0.0"}' ]
  [[ "$(semver_row)" == *"<code>one</code>: ❌ Could not run the check"* ]]
}

@test "a set runs no check while semver_checks is 'false'" {
  workspace_set one:1.1.0 two:0.2.1
  member_index one 1.0.0
  export INPUT_SEMVER_CHECKS=false

  publish

  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_SEMVER_CALLS" ]
  [ -z "$(step_output semver_status)" ]
  [ "$(grep -c '^| Semver |' "$GITHUB_STEP_SUMMARY")" -eq 0 ]
}

@test "one selected member runs the check against its own manifest" {
  workspace_members one:1.0.0 two:1.0.0
  serve_index 0.9.0 false
  export INPUT_PACKAGES=two
  export MOCK_EXPECT_PACKAGE_MANIFEST="$crate_dir/crates/two/Cargo.toml"

  publish

  [ "$status" -eq 0 ]
  [ "$(step_output semver_status)" = passed ]
  grep -Fqx -- "$crate_dir/crates/two/Cargo.toml" "$MOCK_SEMVER_ARGS"
  grep -Fqx -- two "$MOCK_SEMVER_ARGS"
}

### Named registries ###

# cargo-semver-checks takes its baseline from crates.io alone, which
# may hold nothing, or an unrelated crate, under this name.
@test "refuses a named registry, whatever permit_fail says" {
  local permit
  export INPUT_REGISTRY=private MOCK_EXPECT_REGISTRY=private
  export CARGO_REGISTRIES_PRIVATE_INDEX=sparse+https://registry.invalid/
  for permit in false true; do
    export INPUT_PERMIT_FAIL="$permit"
    : > "$GITHUB_OUTPUT"

    publish

    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::semver_checks compares with a baseline from crates.io"*"cannot check a crate for a named registry"* ]]
    [ ! -s "$MOCK_CARGO_LOG" ]
    [ ! -s "$MOCK_CURL_LOG" ]
    [ ! -e "$MOCK_SEMVER_ARGS" ]
    [ "$(step_output publish_status)" = failed ]
    [ -z "$(step_output semver_status)" ]
  done
}

@test "a named registry is fine while semver_checks is 'false'" {
  export INPUT_SEMVER_CHECKS=false
  export INPUT_REGISTRY=private MOCK_EXPECT_REGISTRY=private
  export CARGO_REGISTRIES_PRIVATE_INDEX=sparse+https://registry.invalid/

  publish

  [ "$status" -eq 0 ]
  [ "$(step_output publish_status)" = dry-run ]
  [ -z "$(step_output semver_status)" ]
}

@test "registry 'crates-io' names crates.io and runs the check" {
  serve_index 1.2.0 false
  export INPUT_REGISTRY=crates-io

  publish

  [ "$status" -eq 0 ]
  [ "$(step_output semver_status)" = passed ]
  [ "$(step_output semver_baseline)" = 1.2.0 ]
  grep -q '^https://index.crates.io/' "$MOCK_CURL_LOG"
}

### Skips ###

@test "a first release skips with a notice" {
  export MOCK_INDEX_STATUS=404

  publish

  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::Semver check skipped for example-crate 1.2.3: crates.io holds no earlier release"* ]]
  [ "$(step_output semver_status)" = skipped ]
  [ -z "$(step_output semver_baseline)" ]
  [ "$(step_output publish_status)" = dry-run ]
  [ ! -e "$MOCK_SEMVER_ARGS" ]
  [ "$(wc -l < "$MOCK_CURL_LOG")" -eq 2 ]
  [[ "$(semver_row)" == *"➖ Skipped: no earlier release on crates.io"* ]]
}

@test "only yanked, pre-release or later versions on crates.io skip too" {
  serve_index 1.2.2 true 1.2.4 false 1.3.0-rc.1 false 2.0.0 false

  publish

  [ "$status" -eq 0 ]
  [ "$(step_output semver_status)" = skipped ]
  [ ! -e "$MOCK_SEMVER_ARGS" ]
}

@test "an identical archive already on crates.io skips the check" {
  local sha
  if command -v sha256sum > /dev/null 2>&1; then
    sha="$(head -c 64 /dev/zero | sha256sum)"
  else
    sha="$(head -c 64 /dev/zero | shasum -a 256)"
  fi
  printf '{"name":"example-crate","vers":"1.2.3","cksum":"%s","yanked":false}\n' \
    "${sha%% *}" > "$ws/index.json"
  export MOCK_INDEX_STATUS=200 MOCK_INDEX_BODY="$ws/index.json"

  publish

  [ "$status" -eq 0 ]
  [ "$(step_output registry_status)" = identical ]
  [ "$(step_output semver_status)" = skipped ]
  [[ "$output" == *"this exact archive is already on crates.io"* ]]
  [ "$(wc -l < "$MOCK_CURL_LOG")" -eq 1 ]
  [ ! -e "$MOCK_SEMVER_ARGS" ]
}

### Running the check ###

@test "passes against the latest earlier release, after the crates.io check" {
  serve_index 1.0.0 false 1.2.0 false 1.2.2 true 1.3.0 false 2.0.0-rc.1 false

  publish

  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_SEMVER_ARGS")" = "$(printf '%s\n' check-release \
    --manifest-path "$crate_dir/Cargo.toml" --package example-crate \
    --baseline-version 1.2.0 --color never)" ]
  [ "$(cat "$MOCK_CARGO_LOG")" = $'version\nmetadata\npackage\nsemver-checks\nsemver-checks\ndry-run\nrepackage' ]
  [ "$(step_output semver_status)" = passed ]
  [ "$(step_output semver_baseline)" = 1.2.0 ]
  [ "$(step_output publish_status)" = dry-run ]
  [[ "$output" == *"Checking example-crate 1.2.3 against 1.2.0 from crates.io with cargo-semver-checks 0.51.0"* ]]
  [[ "$output" == *"Summary no semver update required"* ]]
  [ "$(semver_row)" = "| Semver | ✅ Compatible with <code>1.2.0</code> (cargo-semver-checks 0.51.0) |" ]
}

@test "compares against this version when crates.io holds different bytes" {
  serve_index 1.2.0 false 1.2.3 false

  publish

  [ "$status" -eq 0 ]
  [ "$(step_output registry_status)" = different ]
  [ "$(step_output semver_baseline)" = 1.2.3 ]
  [ "$(step_output semver_status)" = passed ]
}

@test "a pre-release compares against the release below it" {
  printf '{"name":"example-crate","version":"1.3.0-rc.2"}\n' > "$MOCK_MANIFEST_JSON"
  serve_index 1.2.9 false 1.3.0-rc.1 false 1.3.0 false

  publish

  [ "$status" -eq 0 ]
  [ "$(step_output semver_baseline)" = 1.2.9 ]
}

@test "versions compare numerically, not as text" {
  serve_index 1.2.10 false 1.2.2 false 1.10.0 false

  publish

  [ "$(step_output semver_baseline)" = 1.2.2 ]
}

# Adjacent components above 2^53 collapse to one value as doubles.
@test "large version components compare exactly" {
  printf '{"name":"example-crate","version":"1.9007199254740992.0"}\n' \
    > "$MOCK_MANIFEST_JSON"
  serve_index 1.9007199254740991.0 false 1.9007199254740993.0 false \
    1.90071992547409910.0 false

  publish

  [ "$status" -eq 0 ]
  [ "$(step_output semver_baseline)" = 1.9007199254740991.0 ]
}

# Valid SemVer 2.0.0 forms from the specification: dotted, hyphenated
# and alphanumeric pre-release identifiers, and build metadata, whose
# identifiers may start with a zero.
@test "valid pre-release and build metadata forms parse" {
  serve_index 1.0.0-alpha.0.x-y false 1.0.0-0A.is.legal false \
    1.0.0--- false 1.1.0+build.01-x false \
    1.2.0-x.7.z.92+exp.sha.5114f85 false 1.1.5+20130313144700 false

  publish

  [ "$status" -eq 0 ]
  [ "$(step_output semver_status)" = passed ]
  [ "$(step_output semver_baseline)" = 1.1.5+20130313144700 ]
}

@test "breaking changes fail the run with a summary row and the tool log" {
  serve_index 1.2.0 false
  export MOCK_SEMVER_STATUS=100

  publish

  [ "$status" -eq 100 ]
  [[ "$output" == *"--- failure function_missing: pub fn removed or renamed ---"* ]]
  [[ "$output" == *"::error::cargo-semver-checks found changes in example-crate 1.2.3 that its version number does not allow, compared with 1.2.0"* ]]
  [ "$(step_output semver_status)" = failed ]
  [ "$(step_output publish_status)" = failed ]
  [ "$(cat "$MOCK_CARGO_LOG")" = $'version\nmetadata\npackage\nsemver-checks\nsemver-checks' ]
  [ "$(semver_row)" = "| Semver | ❌ Breaking changes against <code>1.2.0</code>: <code>function_missing</code>, <code>trait_method_added</code> |" ]
  grep -q '^### ❌ Failed at Check semver' "$GITHUB_STEP_SUMMARY"
}

@test "permit_fail reports a failed check as a warning" {
  serve_index 1.2.0 false
  export MOCK_SEMVER_STATUS=100 INPUT_PERMIT_FAIL=true

  publish

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::Stage 'Check semver' failed (exit 100)"* ]]
  [ "$(step_output semver_status)" = failed ]
  [ "$(step_output publish_status)" = failed ]
  grep -q '^### ⚠️ Failed at Check semver (permitted)' "$GITHUB_STEP_SUMMARY"
}

@test "a tool error fails the run with its exit status" {
  serve_index 1.2.0 false
  export MOCK_SEMVER_STATUS=101

  publish

  [ "$status" -eq 101 ]
  [[ "$output" == *"::error::cargo-semver-checks failed with exit status 101"* ]]
  [ "$(semver_row)" = "| Semver | ❌ cargo-semver-checks failed (exit 101) |" ]
}

@test "an index lookup error fails closed" {
  serve_index 1.2.0 false
  export MOCK_INDEX_STATUS_2=503

  publish

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::the crates.io index answered HTTP 503 for example-crate"* ]]
  [ ! -e "$MOCK_SEMVER_ARGS" ]
  [ "$(step_output semver_status)" = failed ]
  [ "$(semver_row)" = "| Semver | ❌ Could not run the check; see the step log |" ]
  grep -q '^### ❌ Failed at Check semver' "$GITHUB_STEP_SUMMARY"
}

@test "a malformed index entry fails closed" {
  serve_index 1.2.0 false
  printf 'not json\n' > "$ws/broken.json"
  export MOCK_INDEX_BODY_2="$ws/broken.json"

  publish

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::could not parse the crates.io index entry"* ]]
  [ ! -e "$MOCK_SEMVER_ARGS" ]
  [ "$(step_output semver_status)" = failed ]
  [ "$(semver_row)" = "| Semver | ❌ Could not run the check; see the step log |" ]
}

# Valid JSON that holds no usable entry must not read as a first
# release: that would skip the check and let the release through. A
# version outside the SemVer 2.0.0 grammar is no usable entry either:
# read as a pre-release, it would be dropped from the baseline search.
@test "an empty or structurally invalid index fails closed" {
  local body
  serve_index 1.2.0 false
  export MOCK_INDEX_BODY_2="$ws/broken.json"
  for body in '' 'null' '[]' '{}' '"1.2.0"' '[{"vers":"1.2.0"}]' \
    '{"vers":1}' '{"vers":"latest","yanked":false}' \
    '{"vers":"1.2.0","yanked":"false"}' '{"vers":"1.2.0","yanked":null}' \
    '{"vers":"1.2.0-evil/path","yanked":false}' \
    '{"vers":"1.2.0-a..b","yanked":false}' \
    '{"vers":"1.2.0-01","yanked":false}' \
    '{"vers":"01.2.0","yanked":false}' \
    '{"vers":"1.2.0+a..b","yanked":false}' \
    '{"vers":"1.2.0\n","yanked":false}' \
    '{"vers":"1.2.0","yanked":false}
null'; do
    printf '%s' "$body" > "$MOCK_INDEX_BODY_2"
    : > "$MOCK_CURL_LOG"
    : > "$GITHUB_OUTPUT"
    : > "$GITHUB_STEP_SUMMARY"

    publish

    echo "index body: $body"
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::could not parse the crates.io index entry"* ]]
    [ ! -e "$MOCK_SEMVER_ARGS" ]
    [ "$(step_output semver_status)" = failed ]
  done
}

@test "an index entry without a yanked flag still counts" {
  printf '{"vers":"1.2.0"}\n' > "$ws/index.json"
  export MOCK_INDEX_STATUS=200 MOCK_INDEX_BODY="$ws/index.json"

  publish

  [ "$status" -eq 0 ]
  [ "$(step_output semver_status)" = passed ]
  [ "$(step_output semver_baseline)" = 1.2.0 ]
}

@test "a failing version probe fails the stage before the check" {
  serve_index 1.2.0 false
  export MOCK_SEMVER_VERSION_FAIL=true

  publish

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::cargo-semver-checks --version failed"* ]]
  [ "$(step_output semver_status)" = failed ]
  [ "$(step_output semver_baseline)" = 1.2.0 ]
  [ ! -e "$MOCK_SEMVER_ARGS" ]
}

### Environment of the check ###

# Put a wrapper named TOOL in front of its stand-in: the wrapper runs
# BODY, then hands any call BODY did not finish to the stand-in.
wrap_stand_in() {
  mv "$stand_ins/$1" "$stand_ins/$1-inner"
  printf '#!/usr/bin/env bash\n%s\nexec "%s" "$@"\n' "$2" \
    "$stand_ins/$1-inner" > "$stand_ins/$1"
  chmod +x "$stand_ins/$1"
}

@test "an unreachable index fails closed" {
  serve_index 1.2.0 false
  # The crates.io check succeeds; the stage's own request fails.
  # shellcheck disable=SC2016 # literal wrapper code
  wrap_stand_in curl 'if [ -s "$MOCK_CURL_LOG" ]; then exit 6; fi'

  publish

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::could not reach the crates.io index for example-crate"* ]]
  [ "$(step_output semver_status)" = failed ]
  [ ! -e "$MOCK_SEMVER_ARGS" ]
}

# Cargo lets a .cargo/config.toml alias shadow an external subcommand,
# so 'cargo semver-checks' in the checkout could run anything. This
# cargo answers 'semver-checks' as such an alias would.
@test "runs cargo-semver-checks itself, so a Cargo alias cannot fake a pass" {
  serve_index 1.2.0 false
  export MOCK_SEMVER_STATUS=100
  # shellcheck disable=SC2016 # literal wrapper code
  wrap_stand_in cargo 'if [ "${1:-}" = semver-checks ]; then echo "cargo-semver-checks 0.51.0"; exit 0; fi'

  publish

  [ "$status" -eq 100 ]
  [ -e "$MOCK_SEMVER_ARGS" ]
  [ "$(step_output semver_status)" = failed ]
}

@test "runs from an empty directory, pinned, building outside the checkout" {
  serve_index 1.2.0 false
  export MOCK_TOOLCHAIN=1.93.0-x86_64-unknown-linux-gnu

  publish

  [ "$status" -eq 0 ]
  grep -q "^cwd=$RUNNER_TEMP/rust-crate-publish\.[^/]*/semver-cwd$" \
    "$MOCK_SEMVER_ENV"
  semver_env "RUSTUP_TOOLCHAIN=1.93.0-x86_64-unknown-linux-gnu"
  semver_env "CARGO_HOME=$tmp/cargo home"
  grep -q "^CARGO_TARGET_DIR=$RUNNER_TEMP/rust-crate-publish\.[^/]*/semver-target$" \
    "$MOCK_SEMVER_ENV"
}

# cargo-semver-checks resolves crates.io through the source replacement
# its working directory's Cargo config names, so a checked-in config
# could substitute a forged baseline. Verified with 0.51.0: a breaking
# change passed against a replaced crates.io.
@test "a checked-in Cargo config cannot reach the check" {
  serve_index 1.2.0 false
  mkdir "$crate_dir/.cargo"
  printf '[source.crates-io]\nreplace-with = "forged"\n' \
    > "$crate_dir/.cargo/config.toml"
  # shellcheck disable=SC2016 # literal wrapper code
  wrap_stand_in cargo-semver-checks 'if [ -n "$(ls -A)" ]; then exit 42; fi'

  publish

  [ "$status" -eq 0 ]
  [ "$(step_output semver_status)" = passed ]
  run ! semver_env "cwd=$crate_dir"
}

# rustup finds a path toolchain only from the project directory.
@test "a path toolchain runs the check in the project directory" {
  serve_index 1.2.0 false
  export MOCK_TOOLCHAIN="$ws/toolchain"

  publish

  [ "$status" -eq 0 ]
  semver_env "cwd=$crate_dir"
  semver_env "RUSTUP_TOOLCHAIN unset"
}

@test "withholds every scrubbed variable from the check" {
  local name
  serve_index 1.2.0 false
  # Empty tokens carry no credential, so the run is allowed and shows
  # that the scrub removes the names whatever their value.
  export CARGO_REGISTRY_TOKEN="" CARGO_REGISTRIES_CRATES_IO_TOKEN=""
  export CARGO_REGISTRIES_PRIVATE_TOKEN="" ACTIONS_ID_TOKEN_REQUEST_TOKEN=""
  export ACTIONS_ID_TOKEN_REQUEST_URL="" ACTIONS_RUNTIME_TOKEN=runtime-value
  export GITHUB_ENV="$ws/env" GITHUB_PATH="$ws/path" GITHUB_STATE="$ws/state"
  export CARGO_REGISTRIES_PRIVATE_INDEX=sparse+https://registry.invalid/

  publish

  [ "$status" -eq 0 ]
  for name in CARGO_REGISTRY_TOKEN CARGO_REGISTRIES_CRATES_IO_TOKEN \
    CARGO_REGISTRIES_PRIVATE_TOKEN ACTIONS_ID_TOKEN_REQUEST_TOKEN \
    ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_RUNTIME_TOKEN GITHUB_OUTPUT \
    GITHUB_ENV GITHUB_PATH GITHUB_STATE GITHUB_STEP_SUMMARY; do
    semver_env "$name unset"
  done
  semver_env "CARGO_REGISTRIES_PRIVATE_INDEX=sparse+https://registry.invalid/"
  # The action's own writes still land.
  [ "$(step_output semver_status)" = passed ]
  semver_row
}
