#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 AND MIT
# SPDX-FileCopyrightText: 2026 Overture Maps
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Check, package, size-check and publish one crate to crates.io.
#
# Inputs arrive as INPUT_* environment variables (see action.yaml).
# Stages run in order, and the first failure stops the run:
#
#   Check inputs -> Check toolchain -> Read crate metadata
#   -> Verify release tag -> Package -> Check package size
#   -> Match verified digest -> Check crates.io -> Dry-run publish
#   -> Confirm package unchanged -> Publish
#
# The compiling 'Package' stage runs in the project directory, so the
# project's Cargo configuration and toolchain apply to the build. Every
# other stage runs from an empty directory pinned to the same rustup
# toolchain, so a checked-in .cargo/config.toml or rust-toolchain.toml
# cannot reach the upload. Crate code compiled in a job can still read
# that job's credentials, so for isolation verify in one job (dry_run)
# and upload from another given expected_sha256, which compiles nothing.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=job-summary.sh
source "$script_dir/job-summary.sh"

path_prefix="${INPUT_PATH_PREFIX:-.}"
manifest_path="${INPUT_MANIFEST_PATH:-Cargo.toml}"
release_tag="${INPUT_RELEASE_TAG:-}"
max_bytes="${INPUT_MAX_CRATE_SIZE_BYTES:-10485760}"
dry_run="${INPUT_DRY_RUN:-false}"
permit_fail="${INPUT_PERMIT_FAIL:-false}"
summary="${INPUT_SUMMARY:-true}"
expected_sha256="${INPUT_EXPECTED_SHA256:-}"
registry_token="${INPUT_REGISTRY_TOKEN:-}"
# Keep the token out of the environment Cargo and its children inherit.
# This does not hide it from same-user processes that read an
# ancestor's /proc/<pid>/environ; see expected_sha256 for isolation.
unset INPUT_REGISTRY_TOKEN

readonly index_url="https://index.crates.io"
readonly user_agent="rust-crate-publish-action (https://github.com/lfreleng-actions/rust-crate-publish-action)"

crate_name=""
crate_version=""
crate_size=""
crate_sha256=""
cargo_version=""
manifest_display=""
toolchain=""
toolchain_kind=""
toolchain_pin=""
registry_status=""
published_sha256=""
published="false"
publish_status=""
stage="Check inputs"
failure_reason=""
failures_permitted="false"
work_dir=""
if [ -n "$release_tag" ]; then
  tag_cell="⏸️ Not reached"
else
  tag_cell="➖ Not requested"
fi
verification_cell="⏸️ Not reached"
size_cell="⏸️ Not reached"
registry_cell="⏸️ Not reached"

fail() {
  failure_reason="$*"
  echo "::error::$*"
  exit 1
}

warn() {
  summary_note "$*"
  echo "::warning::$*"
}

write_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

render_summary() {
  local status="$1" outcome="" subject="" link=""
  if [ -n "$crate_name" ] && [ -n "$crate_version" ]; then
    subject=": $(summary_cell "$crate_name $crate_version")"
    link="https://crates.io/crates/$crate_name/$crate_version"
  fi
  if [ "$status" -ne 0 ]; then
    if [ "$failures_permitted" = "true" ]; then
      outcome="⚠️ Failed at $(summary_cell "$stage") (permitted)$subject"
    else
      outcome="❌ Failed at $(summary_cell "$stage")$subject"
    fi
  else
    case "$publish_status" in
      published) outcome="🚀 Published$subject" ;;
      skipped) outcome="⛔️ Skipped: previously published$subject" ;;
      *) outcome="✅ Dry run passed$subject" ;;
    esac
  fi

  if [ "$dry_run" = "true" ]; then
    summary_row "Mode" "Dry run: nothing uploaded"
  else
    summary_row "Mode" "Publish to crates.io"
  fi
  if [ -n "$manifest_display" ]; then
    summary_row "Manifest" "$(summary_code "$manifest_display")"
  fi
  case "$toolchain_kind" in
    channel) summary_row "Toolchain" \
      "$(summary_code "cargo ${cargo_version:-unknown}") via $(summary_code "$toolchain")" ;;
    path) summary_row "Toolchain" \
      "⚠️ Path toolchain $(summary_code "$toolchain")" ;;
    none) summary_row "Toolchain" \
      "$(summary_code "cargo ${cargo_version:-unknown}") (no rustup)" ;;
  esac
  summary_row "Release tag" "$tag_cell"
  summary_row "Verification" "$verification_cell"
  summary_row "Package size" "$size_cell"
  summary_row "crates.io" "$registry_cell"
  if [ -n "$crate_sha256" ]; then
    summary_row "SHA-256" "$(summary_code "$crate_sha256")"
  fi
  if [ "$status" -eq 0 ] && [ -n "$link" ] \
    && { [ "$publish_status" = "published" ] \
      || [ "$publish_status" = "skipped" ]; }; then
    summary_row "Link" "🔗 $link"
  fi
  write_summary "$outcome" "$failure_reason"
}

finish() {
  local status=$?
  trap - EXIT
  if [ "$status" -ne 0 ]; then
    publish_status="failed"
    if [ -z "$failure_reason" ]; then
      failure_reason="$stage failed with exit status $status; see the step log for Cargo's output."
    fi
    if [ "$failures_permitted" = "true" ]; then
      failure_reason="$failure_reason permit_fail is 'true', so the step reports success."
    fi
  elif [ -z "$publish_status" ]; then
    publish_status="dry-run"
  fi
  write_output published "$published"
  write_output publish_status "$publish_status"
  if [ "$summary" = "true" ]; then
    render_summary "$status"
  fi
  if [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
    rm -rf -- "$work_dir"
  fi
  if [ "$status" -ne 0 ] && [ "$failures_permitted" = "true" ]; then
    echo "::warning::Stage '$stage' failed (exit $status);" \
      "permit_fail is 'true', so the step reports success"
    exit 0
  fi
  exit "$status"
}
trap finish EXIT

# Run cargo from a directory, pinned to the resolved rustup toolchain,
# with registry tokens and the variables that mint GitHub OIDC tokens
# withheld. Withholding is defence in depth only: same-user code can
# still read them from an ancestor process.
run_cargo_in() {
  local dir="$1"
  shift
  local -a pin=()
  if [ -n "$toolchain_pin" ]; then
    pin=("RUSTUP_TOOLCHAIN=$toolchain_pin")
  fi
  (
    cd -- "$dir"
    exec env -u CARGO_REGISTRY_TOKEN -u CARGO_REGISTRIES_CRATES_IO_TOKEN \
      -u ACTIONS_ID_TOKEN_REQUEST_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL \
      ${pin[@]+"${pin[@]}"} cargo "$@"
  )
}

# The compiling stage alone reads the project's Cargo configuration.
project_cargo() {
  run_cargo_in "$project_dir" "$@"
}

trusted_cargo() {
  run_cargo_in "$trusted_dir" "$@"
}

# Run cargo, echoing its output, and turn its 'warning:' lines into
# annotations. The dry run's abort notice and its already-published
# warning are left out: the action reports both itself.
cargo_with_annotations() {
  local context="$1" log="$work_dir/cargo.log" line message
  shift
  : > "$log"
  "$context" "$@" 2>&1 | tee "$log"
  while IFS= read -r line; do
    case "$line" in
      "warning: aborting upload due to dry run"* \
        | *"already exists on crates.io index"*) continue ;;
    esac
    message="${line#warning: }"
    if grep -Fqx -- "$message" "$work_dir/warnings.seen" 2> /dev/null; then
      continue
    fi
    printf '%s\n' "$message" >> "$work_dir/warnings.seen"
    summary_note "Cargo: $message"
    message=${message//%/%25}
    echo "::warning title=cargo::$message"
  done < <(grep '^warning: ' "$log" || true)
}

# A prefix assignment on 'exec', rather than an 'env NAME=value'
# argument, keeps the token out of the process argument list. An
# explicit token also forces Cargo's built-in provider: a project
# .cargo/config.toml could otherwise name a credential provider, which
# Cargo would run with the token in its environment. Environment
# settings outrank config files.
publishing_cargo() {
  local -a pin=()
  if [ -n "$toolchain_pin" ]; then
    pin=("RUSTUP_TOOLCHAIN=$toolchain_pin")
  fi
  (
    cd -- "$trusted_dir"
    if [ -n "$registry_token" ]; then
      CARGO_REGISTRY_TOKEN="$registry_token" \
        CARGO_REGISTRY_CREDENTIAL_PROVIDER=cargo:token \
        CARGO_REGISTRIES_CRATES_IO_CREDENTIAL_PROVIDER=cargo:token \
        CARGO_REGISTRY_GLOBAL_CREDENTIAL_PROVIDERS=cargo:token \
        exec env -u ACTIONS_ID_TOKEN_REQUEST_TOKEN \
        -u ACTIONS_ID_TOKEN_REQUEST_URL ${pin[@]+"${pin[@]}"} cargo "$@"
    fi
    exec env -u ACTIONS_ID_TOKEN_REQUEST_TOKEN \
      -u ACTIONS_ID_TOKEN_REQUEST_URL ${pin[@]+"${pin[@]}"} cargo "$@"
  )
}

require_boolean() {
  case "$2" in
    true | false) ;;
    *) fail "$1 must be 'true' or 'false'" ;;
  esac
}

# Resolve a path against a base directory unless already absolute.
resolve_against() {
  case "$2" in
    /*) printf '%s' "$2" ;;
    *) printf '%s/%s' "$1" "$2" ;;
  esac
}

require_within_workspace() {
  case "$2/" in
    "$workspace_real"/*) ;;
    *) fail "$1 must resolve within the workspace" ;;
  esac
}

# Print the SHA-256 digest of a file: sha256sum on Linux, shasum on
# macOS.
sha256_of() {
  local digest
  if command -v sha256sum > /dev/null 2>&1; then
    digest="$(sha256sum < "$1")"
  else
    digest="$(shasum -a 256 < "$1")"
  fi
  printf '%s' "${digest%% *}"
}

# Sparse index location of a crate, per the Cargo registry index
# layout: 1/, 2/, 3/<first char>/, otherwise <two>/<two>/.
index_path() {
  local name
  name="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "${#name}" in
    1) printf '1/%s' "$name" ;;
    2) printf '2/%s' "$name" ;;
    3) printf '3/%s/%s' "${name:0:1}" "$name" ;;
    *) printf '%s/%s/%s' "${name:0:2}" "${name:2:2}" "$name" ;;
  esac
}

# Look this version up in the crates.io index and compare its recorded
# checksum, the SHA-256 of the published .crate, with ours. Sets
# registry_status to absent, identical or different. On any failure it
# sets lookup_error and returns 1, leaving the caller to decide.
lookup_registry() {
  local body="$work_dir/index.json" code entry
  lookup_error=""
  if ! code="$(curl -sS --retry 3 -A "$user_agent" -o "$body" \
    -w '%{http_code}' "$index_url/$(index_path "$crate_name")")"; then
    lookup_error="could not reach the crates.io index for $crate_name"
    return 1
  fi
  case "$code" in
    404)
      registry_status="absent"
      return 0
      ;;
    200) ;;
    *)
      lookup_error="the crates.io index answered HTTP $code for $crate_name"
      return 1
      ;;
  esac
  # crates.io rejects versions differing only in build metadata, so
  # compare without it.
  if ! entry="$(jq -c --arg v "${crate_version%%+*}" \
    'select((.vers | split("+")[0]) == $v)' "$body")"; then
    lookup_error="could not parse the crates.io index entry for $crate_name"
    return 1
  fi
  entry="${entry%%$'\n'*}"
  if [ -z "$entry" ]; then
    registry_status="absent"
    return 0
  fi
  published_sha256="$(jq -r '.cksum // empty' <<< "$entry")"
  if [[ ! "$published_sha256" =~ ^[0-9a-f]{64}$ ]]; then
    lookup_error="the crates.io index has no valid checksum for $crate_name $crate_version"
    return 1
  fi
  if [ "$published_sha256" = "$crate_sha256" ]; then
    registry_status="identical"
  else
    registry_status="different"
  fi
}

# The check before an upload fails closed.
query_registry() {
  if ! lookup_registry; then
    fail "$lookup_error"
  fi
}

# A crates.io token for Trusted Publishing is bound to the repository,
# workflow file and optional environment. Name the first two, so a
# rejected token can be checked against the crate's publisher settings.
describe_trusted_publisher() {
  local workflow_file="${GITHUB_WORKFLOW_REF:-unknown}"
  workflow_file="${workflow_file#*/*/}"
  workflow_file="${workflow_file%@*}"
  echo "::notice::Trusted Publisher config surface for $crate_name:" \
    "repository ${GITHUB_REPOSITORY:-unknown}, workflow $workflow_file." \
    "If this job runs under a GitHub Actions environment, the" \
    "crates.io Trusted Publisher config may need that environment too."
}

### Check inputs ###

# Messages name the offending input rather than echoing its value: an
# unvalidated value containing a newline could otherwise start a new
# workflow command.
require_boolean dry_run "$dry_run"
require_boolean permit_fail "$permit_fail"
require_boolean summary "$summary"

# Eighteen digits keeps the value inside a 64-bit shell integer.
if [[ ! "$max_bytes" =~ ^[1-9][0-9]{0,17}$ ]]; then
  fail "max_crate_size_bytes must be a positive integer"
fi

if [ -n "$release_tag" ] && [[ ! "$release_tag" =~ ^[0-9A-Za-z._+-]+$ ]]; then
  fail "release_tag may contain only: 0-9 A-Z a-z . _ + -"
fi

if [ -n "$expected_sha256" ] \
  && [[ ! "$expected_sha256" =~ ^[0-9a-f]{64}$ ]]; then
  fail "expected_sha256 must be 64 lowercase hexadecimal characters"
fi

for tool in cargo jq wc curl mktemp; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    fail "required tool not found on PATH: $tool"
  fi
done
if ! command -v sha256sum > /dev/null 2>&1 \
  && ! command -v shasum > /dev/null 2>&1; then
  fail "required tool not found on PATH: sha256sum or shasum"
fi

workspace="${GITHUB_WORKSPACE:-$PWD}"
if ! workspace_real="$(cd -- "$workspace" 2> /dev/null && pwd -P)"; then
  fail "GITHUB_WORKSPACE is not a directory"
fi

project_dir="$(resolve_against "$workspace_real" "$path_prefix")"
if ! project_dir="$(cd -- "$project_dir" 2> /dev/null && pwd -P)"; then
  fail "path_prefix is not a directory"
fi
require_within_workspace path_prefix "$project_dir"

case "$manifest_path" in
  Cargo.toml | */Cargo.toml) ;;
  *) fail "manifest_path must name a Cargo.toml file" ;;
esac
manifest_file="$(resolve_against "$project_dir" "$manifest_path")"
if [ ! -f "$manifest_file" ]; then
  fail "manifest_path does not exist below path_prefix"
fi
# 'pwd -P' below canonicalises the directory but not the file itself, so
# a symlinked Cargo.toml could point outside the workspace unchecked.
if [ -L "$manifest_file" ]; then
  fail "manifest_path must not be a symlink"
fi
# Canonicalise once, for the containment check below, and hand cargo
# that same path: cargo echoes the manifest path it was given, so the
# metadata lookup then matches whatever symlinks the checkout involves.
manifest_dir="$(cd -- "$(dirname -- "$manifest_file")" && pwd -P)"
manifest_abs="$manifest_dir/Cargo.toml"
require_within_workspace manifest_path "$manifest_abs"
manifest_display="${manifest_abs#"$workspace_real"/}"

# add-mask applies per line, so a multi-line value would leak its tail.
case "$registry_token" in
  *[[:space:]]*) fail "registry_token must not contain whitespace" ;;
esac
if [ -n "$registry_token" ]; then
  echo "::add-mask::$registry_token"
fi

# A dry run with a release tag is a release's verification job: fail it
# for anything that would stop the release, rather than letting the
# later publishing job find out.
release_intent="false"
if [ "$dry_run" = "false" ] || [ -n "$release_tag" ]; then
  release_intent="true"
fi

if ! work_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/rust-crate-publish.XXXXXX")"; then
  work_dir=""
  fail "could not create a temporary directory"
fi
trusted_dir="$work_dir/cwd"
package_target="$work_dir/target"
mkdir -p "$trusted_dir" "$package_target"

# Permit failures only once the inputs are known to be well-formed; a
# misconfigured call should never pass silently.
failures_permitted="$permit_fail"

### Check toolchain ###

# rustup honours a rust-toolchain(.toml) naming an absolute path, and
# then runs that directory's binaries as cargo, so a repository could
# supply its own. 'rustup show active-toolchain' names the selection
# without running it. Channels are rustup-managed, so they are pinned
# for every stage; a path toolchain is never used for an upload.
stage="Check toolchain"
if command -v rustup > /dev/null 2>&1; then
  if ! toolchain="$(cd -- "$project_dir" \
    && rustup show active-toolchain 2> /dev/null)"; then
    fail "could not determine the Rust toolchain rustup selects for" \
      "path_prefix"
  fi
  toolchain="${toolchain%%$'\n'*}"
  toolchain="${toolchain%% *}"
  case "$toolchain" in
    /*) toolchain_kind="path" ;;
    *)
      if [[ ! "$toolchain" =~ ^[A-Za-z0-9._+-]+$ ]]; then
        toolchain=""
        fail "rustup reported an unexpected toolchain name for path_prefix"
      fi
      toolchain_kind="channel"
      toolchain_pin="$toolchain"
      ;;
  esac
else
  toolchain_kind="none"
fi

if [ "$toolchain_kind" = "path" ]; then
  if [ "$release_intent" = "true" ]; then
    fail "path_prefix selects a path-based Rust toolchain through a" \
      "rust-toolchain file; this action will not publish with a" \
      "toolchain the repository supplies. Name a rustup channel instead."
  fi
  warn "path_prefix selects a path-based Rust toolchain; this dry run" \
    "uses it, but a release with it would be refused."
  # Nothing is uploaded, and only that toolchain can reproduce its own
  # archives, so the remaining stages stay in the project context.
  trusted_dir="$project_dir"
fi

cargo_version="$(trusted_cargo --version)"
cargo_version="${cargo_version#cargo }"
cargo_version="${cargo_version%% *}"
if [[ ! "$cargo_version" =~ ^[0-9A-Za-z.+-]+$ ]]; then
  cargo_version="unknown"
fi
write_output cargo_version "$cargo_version"
echo "Toolchain: ${toolchain:-cargo on PATH} (cargo $cargo_version)"

### Read crate metadata ###

stage="Read crate metadata"
metadata="$(trusted_cargo metadata --no-deps --locked --format-version 1 \
  --manifest-path "$manifest_abs")"
# A workspace lists every member: select the requested manifest.
crate_name="$(jq -er --arg manifest "$manifest_abs" \
  '.packages[] | select(.manifest_path == $manifest) | .name
   | strings | select(length > 0)' <<< "$metadata")"
crate_version="$(jq -er --arg manifest "$manifest_abs" \
  '.packages[] | select(.manifest_path == $manifest) | .version
   | strings | select(length > 0)' <<< "$metadata")"
# Cargo enforces these shapes already. Checking them again guarantees
# the values are single-line and safe to write as step outputs.
if [[ ! "$crate_name" =~ ^[A-Za-z0-9_-]+$ ]]; then
  crate_name=""
  fail "cargo metadata returned an unexpected crate name"
fi
if [[ ! "$crate_version" =~ ^[0-9A-Za-z.+-]+$ ]]; then
  crate_version=""
  fail "cargo metadata returned an unexpected crate version"
fi
write_output crate_name "$crate_name"
write_output crate_version "$crate_version"
echo "Crate: $crate_name $crate_version"

### Verify release tag ###

stage="Verify release tag"
if [ -n "$release_tag" ]; then
  expected="${release_tag#v}"
  if [ "$crate_version" != "$expected" ]; then
    tag_cell="❌ $(summary_code "$release_tag") does not match $(summary_code "$crate_version")"
    fail "$crate_name Cargo.toml version ($crate_version) does not" \
      "match release tag ($expected)"
  fi
  tag_cell="✅ $(summary_code "$release_tag") matches"
  echo "$crate_name version $crate_version matches release tag ✅"
fi

### Package ###

# With expected_sha256, an earlier job has already compiled and
# verified this archive, so package without running any crate code;
# the digest check below proves the bytes are the ones it verified.
stage="Package"
crate_file="$package_target/package/$crate_name-$crate_version.crate"
if [ -n "$expected_sha256" ]; then
  trusted_cargo package --no-verify --locked --target-dir "$package_target" \
    --manifest-path "$manifest_abs"
  verification_cell="⏸️ Awaiting digest match"
else
  cargo_with_annotations project_cargo package --locked \
    --target-dir "$package_target" --manifest-path "$manifest_abs"
  verification_cell="✅ Compiled and verified in this job"
fi

### Check package size ###

stage="Check package size"
if [ ! -f "$crate_file" ]; then
  fail "cargo package did not produce $crate_name-$crate_version.crate"
fi
crate_size="$(wc -c < "$crate_file")"
crate_size="${crate_size//[[:space:]]/}"
crate_sha256="$(sha256_of "$crate_file")"
write_output crate_size_bytes "$crate_size"
write_output crate_sha256 "$crate_sha256"
echo "$crate_name package size: $crate_size bytes (limit: $max_bytes)"
echo "$crate_name package SHA-256: $crate_sha256"
if [ "$crate_size" -gt "$max_bytes" ]; then
  size_cell="❌ $(human_bytes "$crate_size"), over the $(human_bytes "$max_bytes") limit"
  fail "$crate_name package is $crate_size bytes, exceeding the" \
    "$max_bytes-byte limit"
fi
size_cell="✅ $(human_bytes "$crate_size") of the $(human_bytes "$max_bytes") limit"

### Match verified digest ###

if [ -n "$expected_sha256" ]; then
  stage="Match verified digest"
  if [ "$crate_sha256" != "$expected_sha256" ]; then
    verification_cell="❌ Differs from the verified digest"
    fail "$crate_name package does not match expected_sha256; not" \
      "publishing. This job packaged it with cargo $cargo_version; if" \
      "the verifying job's cargo_version output differs, pin an exact" \
      "toolchain channel."
  fi
  verification_cell="✅ Matches the digest from an earlier job; not compiled here"
  echo "$crate_name package matches expected_sha256 ✅"
fi

### Check crates.io ###

# crates.io never lets a version be replaced, even once yanked. The
# same bytes there already mean a re-run: skip. Different bytes mean
# the version is taken: fail a release, warn an ordinary dry run.
stage="Check crates.io"
query_registry
case "$registry_status" in
  absent)
    registry_cell="✅ Version not yet published"
    ;;
  identical)
    registry_cell="✅ Already published, identical archive"
    if [ "$dry_run" = "false" ]; then
      write_output registry_status "$registry_status"
      publish_status="skipped"
      echo "$crate_name $crate_version is already on crates.io with" \
        "identical content; skipping the upload ⛔️"
      exit 0
    fi
    ;;
  different)
    if [ "$release_intent" = "true" ]; then
      registry_cell="❌ Already published with different content"
      write_output registry_status "$registry_status"
      fail "$crate_name $crate_version is already on crates.io with" \
        "different content (published SHA-256 $published_sha256)." \
        "crates.io never replaces a version: release a new one."
    fi
    registry_cell="⚠️ Already published with different content"
    warn "$crate_name $crate_version is already on crates.io with" \
      "different content; bump the version before releasing."
    ;;
esac
write_output registry_status "$registry_status"

### Dry-run publish ###

# Registry-side checks only: nothing here compiles.
stage="Dry-run publish"
cargo_with_annotations trusted_cargo publish --dry-run --no-verify --locked \
  --registry crates-io --target-dir "$package_target" \
  --manifest-path "$manifest_abs"

### Confirm package unchanged ###

# Verification ran the crate's build scripts, and Cargo only checks
# that they left the unpacked copy under the target directory alone. A
# script could still edit and commit the workspace sources, which the
# upload would package afresh and never compile. Cargo cannot upload a
# prebuilt archive, so repackage without running crate code and require
# a byte-identical result: Cargo's archives are reproducible, and they
# record the commit, so any change to the packaged inputs shows here.
stage="Confirm package unchanged"
trusted_cargo package --no-verify --locked --target-dir "$package_target" \
  --manifest-path "$manifest_abs"
if [ ! -f "$crate_file" ] \
  || [ "$(sha256_of "$crate_file")" != "$crate_sha256" ]; then
  fail "$crate_name package changed after verification; not publishing"
fi

### Publish ###

if [ "$dry_run" = "true" ]; then
  echo "Dry run: $crate_name $crate_version validated, not published ✅"
  exit 0
fi

stage="Publish"
describe_trusted_publisher
upload_status=0
publishing_cargo publish --no-verify --locked --registry crates-io \
  --target-dir "$package_target" --manifest-path "$manifest_abs" \
  || upload_status=$?
if [ "$upload_status" -ne 0 ]; then
  # An earlier attempt may have uploaded these exact bytes before
  # failing, and the index may only now show them. Best effort: unless
  # the index positively shows this archive, keep Cargo's own failure.
  if lookup_registry && [ "$registry_status" = "identical" ]; then
    registry_cell="✅ Already published, identical archive"
    write_output registry_status "$registry_status"
    publish_status="skipped"
    warn "The upload failed, but crates.io already holds this exact" \
      "archive, likely from an earlier attempt; treating it as published."
    exit 0
  fi
  exit "$upload_status"
fi
published="true"
publish_status="published"
echo "Published $crate_name $crate_version to crates.io ✅"
