#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Stand-in for rustup. Every call records where it ran, its visible
# scrub-relevant variables, and its RUSTUP_AUTO_INSTALL setting and
# arguments in MOCK_RUSTUP_ARGS when set. It answers:
# - 'show active-toolchain' with MOCK_TOOLCHAIN, a channel or a path,
#   and MOCK_TOOLCHAIN_REASON (default 'default'; empty for none), as
#   rustup would;
# - 'which --toolchain NAME cargo' for a NAME listed in the file
#   MOCK_RUSTUP_INSTALLED;
# - 'toolchain install NAME --profile minimal --no-self-update' by
#   adding NAME to that file, or failing with MOCK_RUSTUP_INSTALL_FAIL.

set -euo pipefail

printf '%s\n' "$(pwd -P)" >> "$MOCK_RUSTUP_LOG"
# The same scrub-relevant variables the cargo stand-in records.
{
  env | grep -E '^(CARGO_REGISTRY_[A-Z_]+|CARGO_REGISTRIES_[A-Z0-9_]+|ACTIONS_(ID_TOKEN_REQUEST_(TOKEN|URL)|RUNTIME_TOKEN)|GITHUB_(OUTPUT|ENV|PATH|STATE|STEP_SUMMARY))=' \
    | LC_ALL=C sort | tr '\n' ' ' || true
  echo
} >> "$MOCK_RUSTUP_VARS"
printf '%s|%s\n' "${RUSTUP_AUTO_INSTALL-unset}" "$*" \
  >> "${MOCK_RUSTUP_ARGS:-/dev/null}"

installed() {
  [ -n "${MOCK_RUSTUP_INSTALLED:-}" ] \
    && grep -Fqx -- "$1" "$MOCK_RUSTUP_INSTALLED"
}

case "$*" in
  "show active-toolchain")
    if [ "${MOCK_RUSTUP_FAIL:-false}" = "true" ]; then
      echo "error: toolchain not installed" >&2
      exit 1
    fi
    printf '%s' "${MOCK_TOOLCHAIN:-stable-x86_64-unknown-linux-gnu}"
    if [ -n "${MOCK_TOOLCHAIN_REASON-default}" ]; then
      printf ' (%s)' "${MOCK_TOOLCHAIN_REASON-default}"
    fi
    echo
    ;;
  "which --toolchain "*" cargo")
    [ "$#" -eq 4 ] || exit 90
    if ! installed "$3"; then
      echo "error: toolchain '$3' is not installed" >&2
      exit 1
    fi
    echo "/rustup/toolchains/$3/bin/cargo"
    ;;
  "toolchain install "*" --profile minimal --no-self-update")
    [ "$#" -eq 6 ] || exit 90
    if [ "${MOCK_RUSTUP_INSTALL_FAIL:-false}" = "true" ]; then
      echo "error: could not download toolchain '$3'" >&2
      exit 1
    fi
    printf '%s\n' "$3" >> "${MOCK_RUSTUP_INSTALLED:-/dev/null}"
    ;;
  *) exit 90 ;;
esac
