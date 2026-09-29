#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Stand-in for curl fetching a crates.io sparse index entry. Records the
# URL, writes MOCK_INDEX_BODY to the -o file and prints the HTTP status
# for -w. A second request, after a failed upload, answers with the
# MOCK_INDEX_*_2 values when set.

set -euo pipefail

out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w | -A | --retry) shift 2 ;;
    -sS) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >> "$MOCK_CURL_LOG"
if [ "${MOCK_CURL_FAIL:-false}" = "true" ]; then
  echo "curl: (6) Could not resolve host" >&2
  exit 6
fi

status="${MOCK_INDEX_STATUS:-404}"
body="${MOCK_INDEX_BODY:-}"
if [ "$(wc -l < "$MOCK_CURL_LOG")" -gt 1 ]; then
  status="${MOCK_INDEX_STATUS_2:-$status}"
  body="${MOCK_INDEX_BODY_2:-$body}"
fi
if [ -n "$body" ]; then
  cp "$body" "$out"
else
  : > "$out"
fi
printf '%s' "$status"
