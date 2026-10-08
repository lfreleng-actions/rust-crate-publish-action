#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Stand-in for cargo-semver-checks, run directly as
# 'cargo-semver-checks semver-checks <args>'. Each call appends
# 'semver-checks' to MOCK_CARGO_LOG, so tests see it among the cargo
# stages. '--version' prints MOCK_SEMVER_VERSION, or fails when
# MOCK_SEMVER_VERSION_FAIL is 'true'. 'check-release' records its
# arguments one per line in MOCK_SEMVER_ARGS and, in MOCK_SEMVER_ENV,
# its working directory and the variables the action sets or
# withholds, then prints a report and exits MOCK_SEMVER_STATUS (100:
# lints failed). With MOCK_SEMVER_CALLS set, each check-release call
# also appends its arguments there on one line, and a package named in
# MOCK_SEMVER_FAIL_PACKAGE exits 100 instead.

set -euo pipefail

[ "${1:-}" = "semver-checks" ] || exit 90
shift
printf '%s\n' semver-checks >> "$MOCK_CARGO_LOG"
if [ "$*" = "--version" ]; then
  if [ "${MOCK_SEMVER_VERSION_FAIL:-false}" = "true" ]; then
    echo "error: broken install" >&2
    exit 3
  fi
  echo "cargo-semver-checks ${MOCK_SEMVER_VERSION:-0.51.0}"
  exit 0
fi
[ "${1:-}" = "check-release" ] || exit 91

printf '%s\n' "$@" > "$MOCK_SEMVER_ARGS"
status="${MOCK_SEMVER_STATUS:-0}"
if [ -n "${MOCK_SEMVER_CALLS:-}" ]; then
  printf '%s\n' "$*" >> "$MOCK_SEMVER_CALLS"
  args=" $* "
  if [ -n "${MOCK_SEMVER_FAIL_PACKAGE:-}" ] \
    && [[ "$args" == *" --package $MOCK_SEMVER_FAIL_PACKAGE "* ]]; then
    status=100
  fi
fi
{
  printf 'cwd=%s\n' "$(pwd -P)"
  for name in CARGO_TARGET_DIR RUSTUP_TOOLCHAIN CARGO_HOME CARGO_REGISTRY_TOKEN \
    CARGO_REGISTRIES_CRATES_IO_TOKEN CARGO_REGISTRIES_PRIVATE_TOKEN \
    CARGO_REGISTRIES_PRIVATE_INDEX ACTIONS_ID_TOKEN_REQUEST_TOKEN \
    ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_RUNTIME_TOKEN GITHUB_OUTPUT \
    GITHUB_ENV GITHUB_PATH GITHUB_STATE GITHUB_STEP_SUMMARY; do
    if [ -n "${!name+set}" ]; then
      printf '%s=%s\n' "$name" "${!name}"
    else
      printf '%s unset\n' "$name"
    fi
  done
} > "$MOCK_SEMVER_ENV"

echo "    Checking example-crate (current) against the baseline"
case "$status" in
  0)
    echo "     Summary no semver update required"
    ;;
  100)
    echo "--- failure function_missing: pub fn removed or renamed ---"
    echo "--- failure trait_method_added: pub trait method added ---"
    echo "--- failure function_missing: pub fn removed or renamed ---"
    echo "--- failure Not|A_lint: crafted line ---"
    echo "     Summary semver requires new major version: 2 major and 0 minor checks failed"
    ;;
  *)
    echo "error: failed to build rustdoc for the baseline" >&2
    ;;
esac
exit "$status"
