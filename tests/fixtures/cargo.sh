#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Overture Maps
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Stand-in for cargo. Checks each call's exact arguments, records the
# stage, working directory and visible credentials, then simulates the
# side effects publish-crate.sh depends on. '@TARGET' in an expected
# argument list accepts any non-empty value and records it.
#
# With MOCK_WORKSPACE_JSON set, metadata reports that workspace, and
# package and publish calls also accept trailing '-p NAME' pairs: the
# named crates are packaged as one set, and a real publish of a set
# records each upload in MOCK_INDEX_DIR, as crates.io's index would.

set -euo pipefail

manifest="$MOCK_EXPECT_MANIFEST"
# MOCK_EXPECT_REGISTRY names the registry a test expects; unset means
# crates.io, which packaging leaves implicit.
package_registry=()
if [ -n "${MOCK_EXPECT_REGISTRY:-}" ]; then
  package_registry=(--registry "$MOCK_EXPECT_REGISTRY")
fi
publish_registry="${MOCK_EXPECT_REGISTRY:-crates-io}"
member_manifest="${MOCK_EXPECT_PACKAGE_MANIFEST:-$manifest}"
case "${1:-}" in
  --version)
    stage=version
    expected=(--version)
    ;;
  metadata)
    stage=metadata
    expected=(metadata --no-deps --locked --format-version 1
      --manifest-path "$manifest")
    ;;
  package)
    if [ "${2:-}" = "--no-verify" ]; then
      stage=repackage
      expected=(package --no-verify --locked
        ${package_registry[@]+"${package_registry[@]}"} --target-dir @TARGET
        --manifest-path @MANIFEST)
    else
      stage=package
      expected=(package --locked
        ${package_registry[@]+"${package_registry[@]}"} --target-dir @TARGET
        --manifest-path @MANIFEST)
    fi
    ;;
  publish)
    if [ "${2:-}" = "--dry-run" ]; then
      stage=dry-run
      expected=(publish --dry-run --no-verify --locked
        --registry "$publish_registry" --target-dir @TARGET
        --manifest-path @MANIFEST)
    else
      stage=publish
      expected=(publish --no-verify --locked --registry "$publish_registry"
        --target-dir @TARGET --manifest-path @MANIFEST)
    fi
    ;;
  *)
    echo "Unexpected cargo command: ${1:-}" >&2
    exit 90
    ;;
esac

printf '%s\n' "$stage" >> "$MOCK_CARGO_LOG"
printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$stage" "$(pwd -P)" \
  "${CARGO_REGISTRY_TOKEN-unset}" \
  "${CARGO_REGISTRIES_CRATES_IO_TOKEN-unset}" \
  "${ACTIONS_ID_TOKEN_REQUEST_TOKEN-unset}" \
  "${INPUT_REGISTRY_TOKEN-unset}" \
  "${CARGO_REGISTRY_CREDENTIAL_PROVIDER-unset}" \
  "${RUSTUP_TOOLCHAIN-unset}" >> "$MOCK_CARGO_ENV"
# Every registry, GitHub token or runner command file variable this
# stage can see, as sorted NAME=value pairs, for the scrub tests. Runners
# set other ACTIONS_* variables the action has no reason to withhold.
{
  printf '%s|' "$stage"
  env | grep -E '^(CARGO_REGISTRY_[A-Z_]+|CARGO_REGISTRIES_[A-Z0-9_]+|ACTIONS_(ID_TOKEN_REQUEST_(TOKEN|URL)|RUNTIME_TOKEN)|GITHUB_(OUTPUT|ENV|PATH|STATE|STEP_SUMMARY))=' \
    | LC_ALL=C sort | tr '\n' ' ' || true
  echo
} >> "$MOCK_CARGO_VARS"

[ "$#" -ge "${#expected[@]}" ] || exit 91
target=""
given_manifest=""
for argument in "${expected[@]}"; do
  case "$argument" in
    @TARGET)
      [ -n "$1" ] || exit 92
      target="$1"
      ;;
    @MANIFEST) given_manifest="$1" ;;
    *) [ "$1" = "$argument" ] || exit 92 ;;
  esac
  shift
done

# Trailing '-p NAME' pairs select a set of workspace members, which
# Cargo resolves through the workspace manifest.
selected=()
while [ "$#" -gt 0 ]; do
  [ "$1" = "-p" ] && [ "$#" -ge 2 ] && [ -n "${MOCK_WORKSPACE_JSON:-}" ] \
    || exit 93
  selected+=("$2")
  shift 2
done
if [ -n "$given_manifest" ]; then
  if [ "${#selected[@]}" -gt 0 ]; then
    [ "$given_manifest" = "$manifest" ] || exit 92
    printf '%s %s\n' "$stage" "${selected[*]}" >> "$MOCK_CARGO_SETS"
  else
    [ "$given_manifest" = "$member_manifest" ] || exit 92
  fi
fi
if [ -n "$target" ]; then
  printf '%s\n' "$target" >> "$MOCK_CARGO_TARGETS"
fi

if [ "${MOCK_FAIL_STAGE:-}" = "$stage" ]; then
  echo "Mock cargo $stage failed" >&2
  exit 42
fi

if [ -n "${MOCK_CARGO_WARNING:-}" ]; then
  case "$stage" in
    package | dry-run) echo "warning: $MOCK_CARGO_WARNING" >&2 ;;
  esac
fi

# Name and version of a crate: a workspace member by name, else the
# single manifest's package (MOCK_MANIFEST_JSON, or the workspace
# member at the manifest path given).
crate_id() {
  if [ -n "${1:-}" ]; then
    jq -er --arg n "$1" \
      '.[] | select(.name == $n) | .name + "-" + .version' \
      "$MOCK_WORKSPACE_JSON"
  elif [ -n "${MOCK_WORKSPACE_JSON:-}" ] && [ -n "${MOCK_EXPECT_PACKAGE_MANIFEST:-}" ]; then
    jq -er --arg m "$member_manifest" \
      '.[] | select(.manifest_path == $m) | .name + "-" + .version' \
      "$MOCK_WORKSPACE_JSON"
  else
    jq -r '.name + "-" + .version' "$MOCK_MANIFEST_JSON"
  fi
}

# Write one archive. A crate packaged within a set starts with its own
# name, so each member of a set has a distinct digest; a single crate
# is MOCK_CRATE_SIZE zero bytes.
write_crate() {
  local file
  file="$target/package/$(crate_id "${1:-}").crate"
  mkdir -p "$target/package"
  {
    printf '%s' "${1:-}"
    head -c "$MOCK_CRATE_SIZE" /dev/zero
  } > "$file"
  if [ "$stage" = repackage ] && { [ "${MOCK_TAMPER:-false}" = "true" ] \
    || [ "${MOCK_TAMPER:-false}" = "${1:-}" ]; }; then
    printf 'x' >> "$file"
  fi
}

package_all() {
  local name
  if [ "${MOCK_MISSING_PACKAGE:-false}" = "true" ]; then
    return 0
  fi
  if [ "${#selected[@]}" -eq 0 ]; then
    write_crate ""
    return 0
  fi
  for name in "${selected[@]}"; do
    if [ "${MOCK_MISSING_PACKAGE:-false}" != "$name" ]; then
      write_crate "$name"
    fi
  done
}

sha256() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum < "$1" | cut -d' ' -f1
  else
    shasum -a 256 < "$1" | cut -d' ' -f1
  fi
}

# Record a crate version in the index with the given checksum.
index_entry() {
  local id
  id="$(crate_id "$1")"
  jq -cn --arg n "$1" --arg v "${id#"$1"-}" --arg c "$2" \
    '{name: $n, vers: $v, cksum: $c, yanked: false}' \
    >> "$MOCK_INDEX_DIR/$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
}

# Upload each crate of a set in turn, recording it in the index, until
# MOCK_PUBLISH_FAIL_AT names the crate whose upload fails. With
# MOCK_RACE_CKSUM set, another publisher's archive with that checksum
# reaches the index for the failing crate first.
upload_all() {
  local name file
  for name in "${selected[@]}"; do
    if [ "${MOCK_PUBLISH_FAIL_AT:-}" = "$name" ]; then
      if [ -n "${MOCK_RACE_CKSUM:-}" ]; then
        index_entry "$name" "$MOCK_RACE_CKSUM"
      fi
      echo "Mock upload of $name failed" >&2
      exit 43
    fi
    file="$target/package/$(crate_id "$name").crate"
    write_crate "$name"
    index_entry "$name" "$(sha256 "$file")"
  done
}

case "$stage" in
  version)
    echo "cargo ${MOCK_CARGO_VERSION:-1.98.1} (mock 2026-01-01)"
    ;;
  metadata)
    if [ -n "${MOCK_WORKSPACE_JSON:-}" ]; then
      jq '{packages: ., workspace_members: map(.id)}' "$MOCK_WORKSPACE_JSON"
      exit 0
    fi
    other_packages="[]"
    if [ "${MOCK_INCLUDE_OTHER_PACKAGE:-false}" = "true" ]; then
      other_packages='[{"name":"other-crate","version":"9.9.9",
        "manifest_path":"/workspace/other-crate/Cargo.toml"}]'
    fi
    jq -n --arg manifest "$manifest" \
      --argjson pkg "$(cat "$MOCK_MANIFEST_JSON")" \
      --argjson extra "$other_packages" \
      '{packages: ($extra + [($pkg + {manifest_path: $manifest})])}'
    ;;
  package | repackage)
    # Identical bytes on repackaging, as Cargo's reproducible archives
    # give, unless the test simulates sources changed after
    # verification.
    package_all
    ;;
  dry-run)
    if [ -n "${MOCK_DRY_RUN_EXISTS:-}" ]; then
      echo "warning: crate example-crate@1.2.3 already exists on $MOCK_DRY_RUN_EXISTS" >&2
    fi
    echo "warning: aborting upload due to dry run" >&2
    ;;
  publish)
    if [ "${#selected[@]}" -gt 0 ]; then
      upload_all
    fi
    ;;
esac
