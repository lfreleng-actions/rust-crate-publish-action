#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Stand-in for 'rustup show active-toolchain': records where it ran and
# names MOCK_TOOLCHAIN, a channel or a path, as rustup would.

set -euo pipefail

printf '%s\n' "$(pwd -P)" >> "$MOCK_RUSTUP_LOG"
# The same scrub-relevant variables the cargo stand-in records.
{
  env | grep -E '^(CARGO_REGISTRY_[A-Z_]+|CARGO_REGISTRIES_[A-Z0-9_]+|ACTIONS_(ID_TOKEN_REQUEST_(TOKEN|URL)|RUNTIME_TOKEN)|GITHUB_(OUTPUT|ENV|PATH|STATE|STEP_SUMMARY))=' \
    | LC_ALL=C sort | tr '\n' ' ' || true
  echo
} >> "$MOCK_RUSTUP_VARS"
[ "$*" = "show active-toolchain" ] || exit 90
if [ "${MOCK_RUSTUP_FAIL:-false}" = "true" ]; then
  echo "error: toolchain not installed" >&2
  exit 1
fi
echo "${MOCK_TOOLCHAIN:-stable-x86_64-unknown-linux-gnu} (default)"
