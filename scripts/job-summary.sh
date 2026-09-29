#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Overture Maps
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Job summary helpers, sourced by publish-crate.sh.
#
# Callers build each table cell themselves, passing any value that did
# not come from this action through summary_cell or summary_code, and
# hand the finished cells to summary_row.

summary_rows=()
summary_notes=()

# Escape a value for a single Markdown table cell: HTML metacharacters,
# the column delimiter, backticks and line breaks. The replacements are
# quoted so '&' stays literal under bash 5.2 patsub_replacement and
# no backslash leaks through on bash 3.2.
summary_cell() {
  local value="$1"
  value=${value//&/"&amp;"}
  value=${value//</"&lt;"}
  value=${value//>/"&gt;"}
  value=${value//|/"&#124;"}
  value=${value//\`/"&#96;"}
  value=${value//$'\r'/" "}
  value=${value//$'\n'/" "}
  printf '%s' "$value"
}

# Render a value as inline code. An HTML code element, unlike a
# backtick span, keeps working once summary_cell has escaped the value.
summary_code() {
  printf '<code>%s</code>' "$(summary_cell "$1")"
}

# Format a byte count for people: '6.8 KiB', '10.0 MiB'.
human_bytes() {
  awk -v bytes="$1" 'BEGIN {
    split("B KiB MiB GiB TiB", unit, " ")
    i = 1
    while (bytes >= 1024 && i < 5) { bytes /= 1024; i++ }
    if (i == 1) printf "%d %s", bytes, unit[i]
    else printf "%.1f %s", bytes, unit[i]
  }'
}

# Queue one table row; the cell must already be escaped.
summary_row() {
  summary_rows+=("| $1 | $2 |")
}

# Queue one note for the list under the table; escaped here.
summary_note() {
  summary_notes+=("- $(summary_cell "$1")")
}

# Append the summary to $GITHUB_STEP_SUMMARY. Arguments: the outcome
# line (already escaped) and a plain-text failure reason, empty on
# success. A write failure warns rather than changing the exit status.
# The text is appended by one simple command: bash does not report a
# failed redirection on a compound command to a surrounding 'if'.
write_summary() {
  local outcome="$1" reason="$2" line text
  if [ -z "${GITHUB_STEP_SUMMARY:-}" ]; then
    return 0
  fi
  text="$(
    printf '\n## 🦀 Rust Crate Publish\n\n### %s\n\n' "$outcome"
    if [ -n "$reason" ]; then
      printf '%s\n\n' "$(summary_cell "$reason")"
    fi
    printf '| Check | Result |\n| --- | --- |\n'
    for line in ${summary_rows[@]+"${summary_rows[@]}"}; do
      printf '%s\n' "$line"
    done
    if [ "${#summary_notes[@]}" -gt 0 ]; then
      printf '\n**Warnings**\n\n'
      for line in "${summary_notes[@]}"; do
        printf '%s\n' "$line"
      done
    fi
  )"
  if ! printf '%s\n' "$text" 2> /dev/null >> "$GITHUB_STEP_SUMMARY"; then
    echo "::warning::Could not write crate publishing job summary" >&2
  fi
}
