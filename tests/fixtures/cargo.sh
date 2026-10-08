#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Overture Maps
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Stand-in for cargo. Checks each call's exact arguments, records the
# stage, working directory and visible credentials, then simulates the
# side effects publish-crate.sh depends on. '@TARGET' in an expected
# argument list accepts any non-empty value and records it.

set -euo pipefail

manifest="$MOCK_EXPECT_MANIFEST"
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
      expected=(package --no-verify --locked --target-dir @TARGET
        --manifest-path "$manifest")
    else
      stage=package
      expected=(package --locked --target-dir @TARGET
        --manifest-path "$manifest")
    fi
    ;;
  publish)
    if [ "${2:-}" = "--dry-run" ]; then
      stage=dry-run
      expected=(publish --dry-run --no-verify --locked --registry crates-io
        --target-dir @TARGET --manifest-path "$manifest")
    else
      stage=publish
      expected=(publish --no-verify --locked --registry crates-io
        --target-dir @TARGET --manifest-path "$manifest")
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

[ "$#" -eq "${#expected[@]}" ] || exit 91
target=""
for argument in "${expected[@]}"; do
  if [ "$argument" = "@TARGET" ]; then
    [ -n "$1" ] || exit 92
    target="$1"
  else
    [ "$1" = "$argument" ] || exit 92
  fi
  shift
done
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

crate_file() {
  printf '%s/package/%s.crate' "$target" \
    "$(jq -r '.name + "-" + .version' "$MOCK_MANIFEST_JSON")"
}

case "$stage" in
  version)
    echo "cargo ${MOCK_CARGO_VERSION:-1.98.1} (mock 2026-01-01)"
    ;;
  metadata)
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
  package)
    if [ "${MOCK_MISSING_PACKAGE:-false}" != "true" ]; then
      mkdir -p "$target/package"
      head -c "$MOCK_CRATE_SIZE" /dev/zero > "$(crate_file)"
    fi
    ;;
  repackage)
    # Identical bytes, as Cargo's reproducible archives give, unless the
    # test simulates sources changed after verification.
    if [ "${MOCK_MISSING_PACKAGE:-false}" != "true" ]; then
      mkdir -p "$target/package"
      head -c "$MOCK_CRATE_SIZE" /dev/zero > "$(crate_file)"
      if [ "${MOCK_TAMPER:-false}" = "true" ]; then
        printf 'x' >> "$(crate_file)"
      fi
    fi
    ;;
  dry-run)
    echo "warning: aborting upload due to dry run" >&2
    ;;
esac
