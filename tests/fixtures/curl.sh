#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Stand-in for curl fetching a sparse index entry. Records the URL,
# writes MOCK_INDEX_BODY to the -o file and prints the HTTP status for
# -w. A second entry request, after a failed upload, answers with the
# MOCK_INDEX_*_2 values when set. A named registry's config.json
# answers with MOCK_CONFIG_STATUS and MOCK_CONFIG_BODY, by default a
# valid config with an HTTPS API. With MOCK_INDEX_DIR set, an entry
# request serves the file named after the crate there instead, and
# MOCK_INDEX_DIR_MISSING (default 404) without one.

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

if [[ "$url" == */config.json ]]; then
  if [ -n "${MOCK_CONFIG_BODY:-}" ]; then
    printf '%s\n' "$MOCK_CONFIG_BODY" > "$out"
  else
    printf '%s\n' '{"dl":"https://dl.example.test/crates",' \
      '"api":"https://api.example.test"}' > "$out"
  fi
  printf '%s' "${MOCK_CONFIG_STATUS:-200}"
  exit 0
fi

if [ -n "${MOCK_INDEX_DIR:-}" ]; then
  entry="$MOCK_INDEX_DIR/${url##*/}"
  if [ -f "$entry" ]; then
    cp "$entry" "$out"
    printf '200'
  else
    : > "$out"
    printf '%s' "${MOCK_INDEX_DIR_MISSING:-404}"
  fi
  exit 0
fi

status="${MOCK_INDEX_STATUS:-404}"
body="${MOCK_INDEX_BODY:-}"
if [ "$(grep -vc '/config\.json$' "$MOCK_CURL_LOG")" -gt 1 ]; then
  status="${MOCK_INDEX_STATUS_2:-$status}"
  body="${MOCK_INDEX_BODY_2:-$body}"
fi
if [ -n "$body" ]; then
  cp "$body" "$out"
else
  : > "$out"
fi
printf '%s' "$status"
