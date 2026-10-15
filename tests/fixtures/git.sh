#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Stand-in for git that records each call's subcommand in the cargo
# call log, as 'git-<subcommand>', so tests see where git runs among
# the Cargo stages, and the scrub-relevant variables it can see in the
# cargo variables log. It then runs the real git, MOCK_REAL_GIT.

set -euo pipefail

subcommand=""
for argument in "$@"; do
  case "$argument" in
    -*) ;;
    *)
      subcommand="$argument"
      break
      ;;
  esac
done
printf 'git-%s\n' "$subcommand" >> "$MOCK_CARGO_LOG"
{
  printf 'git-%s|' "$subcommand"
  env | grep -E '^(CARGO_REGISTRY_[A-Z_]+|CARGO_REGISTRIES_[A-Z0-9_]+|ACTIONS_(ID_TOKEN_REQUEST_(TOKEN|URL)|RUNTIME_TOKEN)|GITHUB_(OUTPUT|ENV|PATH|STATE|STEP_SUMMARY))=' \
    | LC_ALL=C sort | tr '\n' ' ' || true
  echo
} >> "$MOCK_CARGO_VARS"
exec "$MOCK_REAL_GIT" "$@"
