#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Tag-based versioning for publish-crate.sh. A tag-versioned project
# keeps the placeholder version 0.0.0 in Cargo.toml, and the 'version'
# input names the release; the 'Stamp version' stage writes it into
# the checkout before any Cargo command packages the crate.
#
# lfreleng-actions/rust-build-action applies the same rewrite from the
# same specification, and both repositories test it against the same
# vectors (tests/fixtures/version-stamp/). The release lane requires
# the .crate that rust-build-action packages to equal the one this
# action verifies and uploads, so the two must stay byte-identical.
#
# publish-crate.sh sources this file, calls stamp_check_input while it
# checks inputs, and stamp_version_stage once the toolchain is known.
# The rewrite is text processing alone: it runs no Cargo command and no
# project code. Cargo reads the result under the usual environment
# scrub, and so does git.

# Globals shared with publish-crate.sh are assigned there (SC2154) or
# read there (SC2034).
# shellcheck disable=SC2154,SC2034

readonly stamp_placeholder="0.0.0"
# SemVer 2.0, without a leading 'v'; a numeric pre-release identifier
# carries no leading zero.
readonly stamp_semver_re='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'

# '--allow-dirty' once the stage has confirmed that the rewrite is the
# checkout's only change; empty otherwise, and always without 'version'.
dirty_args=()
stamp_root=""
stamp_top=""
stamp_lock=""
# Paths, relative to the repository root, of the files the rewrite
# may have modified; compared whole, since a path may hold a newline.
stamp_allowed=()
stamp_names=()
stamp_versions=()
stamp_manifests=()
# The files the rewrite covered, each with a copy of its stamped
# content in the work directory and, in stamp_exec, 'x' when it was
# executable then and '-' otherwise.
stamp_files=()
stamp_exec=()

# Line endings: every line keeps exactly its own ending, CRLF, LF or
# none for a final line without a newline, and the rules match the
# line without it. This rule, put before both programs below, strips
# a CR ending from each record and notes it in 'cr'. The record that
# 'unterminated' numbers ends the file without a newline, so a CR
# there is content, not an ending.
# shellcheck disable=SC2016 # awk, not shell, expands these
readonly stamp_awk_line='
{ cr = (NR != unterminated && sub(/\r$/, "")) }'

# Print each record followed by its ending, adding the final newline
# only when the input ended with one, so no byte changes besides the
# version. Appended to both programs below.
readonly stamp_awk_emit='
function emit(line, cr) {
  printf "%s%s%s", (emitted++ ? "\n" : ""), line, (cr ? "\r" : "")
}
END { if (emitted && final_nl) printf "\n" }'

# Manifest rule: on every line, replace each match of
#   (^|[[:space:]{,])(version[[:space:]]*=[[:space:]]*"(=|\^|~)?)0\.0\.0"
# with \1\2<version>". A leading space stands in for '^', so one
# expression serves every match; it is removed again before printing.
# shellcheck disable=SC2016 # awk, not shell, expands these
readonly stamp_manifest_awk='
{
  rest = " " $0
  out = ""
  while (match(rest, /[[:space:]{,]version[[:space:]]*=[[:space:]]*"[=^~]?0\.0\.0"/)) {
    out = out substr(rest, 1, RSTART + RLENGTH - 7) version "\""
    rest = substr(rest, RSTART + RLENGTH)
  }
  emit(substr(out rest, 2), cr)
}'

# Lockfile rule: a section runs from one line starting with '[' to the
# next, so [[patch.unused]], [metadata] and any other header end a
# [[package]] section, and only [[package]] sections change. In one
# whose first name line names a workspace member, and which has no
# source line, each line reading exactly version = "0.0.0" takes the
# new version. On every line of every [[package]] section, so in a
# dependencies array on one line or several, an entry "<member> 0.0.0"
# does too. Nothing else changes.
# shellcheck disable=SC2016 # awk, not shell, expands these
readonly stamp_lock_awk='
BEGIN {
  count = split(members, list, " ")
  for (i = 1; i <= count; i++) member[list[i]] = 1
  held = 0
}
function deps(line,   i, from, to, out, at) {
  for (i = 1; i <= count; i++) {
    from = "\"" list[i] " " placeholder "\""
    to = "\"" list[i] " " version "\""
    out = ""
    while ((at = index(line, from)) > 0) {
      out = out substr(line, 1, at - 1) to
      line = substr(line, at + length(from))
    }
    line = out line
  }
  return line
}
function flush(   i, stamp) {
  stamp = in_block && named && (name in member) && !sourced
  for (i = 1; i <= held; i++) {
    if (stamp && buf[i] == "version = \"" placeholder "\"")
      buf[i] = "version = \"" version "\""
    emit(buf[i], buf_cr[i])
  }
  held = 0
  named = 0
  sourced = 0
}
/^\[/ {
  flush()
  in_block = ($0 == "[[package]]")
}
{
  line = $0
  if (in_block && !named && line ~ /^name = "[^"]*"$/) {
    name = substr(line, 9, length(line) - 9)
    named = 1
  }
  if (in_block && substr(line, 1, 9) == "source = ") sourced = 1
  if (in_block) line = deps(line)
  buf[++held] = line
  buf_cr[held] = cr
}
END { flush() }'

# Check the 'version' input; publish-crate.sh calls this while it checks
# inputs. Messages name the input and never echo its value.
stamp_check_input() {
  if [ -z "$version_input" ]; then
    return 0
  fi
  if [[ ! "$version_input" =~ $stamp_semver_re ]]; then
    fail "version must be a SemVer 2.0 version such as 1.2.3 or" \
      "1.2.3-rc.1, without a leading 'v'"
  fi
  # The tag check compares against the stamped version, so a tag that
  # disagrees could never pass it.
  if [ -n "$release_tag" ] && [ "${release_tag#v}" != "$version_input" ]; then
    fail "release_tag and version disagree: release_tag, less one" \
      "leading 'v', must equal version"
  fi
}

# Read the workspace root and every member's name, version and manifest
# from 'cargo metadata' JSON into stamp_root and the stamp_* arrays.
stamp_read_members() {
  local metadata_json="$1" name version manifest
  stamp_names=()
  stamp_versions=()
  stamp_manifests=()
  if ! jq -e '(.workspace_root | type == "string"
      and startswith("/") and (test("[[:cntrl:]\\\\]") | not))
    and (.workspace_members | type == "array" and length > 0)
    and (.workspace_members as $ids
      | [.packages[] | select(.id | IN($ids[]))]
      | length == ($ids | length)
        and all(.[];
          (.name | type == "string" and test("^[A-Za-z0-9_-]+$"))
          and (.version | type == "string" and test("^[0-9A-Za-z.+-]+$"))
          and (.manifest_path | type == "string"
            and startswith("/") and (test("[[:cntrl:]\\\\]") | not))))' \
    <<< "$metadata_json" > /dev/null 2>&1; then
    fail "cargo metadata returned unexpected workspace members"
  fi
  stamp_root="$(jq -r '.workspace_root' <<< "$metadata_json")"
  # Cargo reports paths as it reached them, symlinks included.
  stamp_root="$(cd -- "$stamp_root" && pwd -P)" \
    || fail "could not resolve the workspace root"
  while IFS=$'\t' read -r name version manifest; do
    stamp_names+=("$name")
    stamp_versions+=("$version")
    stamp_manifests+=("$manifest")
  done < <(jq -r '.workspace_members as $ids | .packages[]
    | select(.id | IN($ids[])) | [.name, .version, .manifest_path] | @tsv' \
    <<< "$metadata_json")
}

# Rewrite FILE in place with the awk PROGRAM, passing any further
# arguments to awk. Writing through the existing file keeps its mode.
stamp_rewrite() {
  local file="$1" program="$2" tmp="$work_dir/stamp.tmp" final_nl=0
  local unterminated=0 newlines
  shift 2
  if [ -z "$(tail -c 1 -- "$file")" ]; then
    final_nl=1
  else
    # The last record, which no newline ends, follows the last newline.
    newlines="$(wc -l < "$file")" || fail "could not read ${file#"$workspace_real"/}"
    unterminated=$((newlines + 1))
  fi
  if ! LC_ALL=C awk -v version="$version_input" -v final_nl="$final_nl" \
    -v unterminated="$unterminated" -v placeholder="$stamp_placeholder" \
    "$@" "$stamp_awk_line$program$stamp_awk_emit" "$file" > "$tmp"; then
    fail "could not rewrite ${file#"$workspace_real"/}"
  fi
  if ! cmp -s -- "$tmp" "$file"; then
    cat -- "$tmp" > "$file" || fail "could not write ${file#"$workspace_real"/}"
    echo "Stamped $version_input into ${file#"$workspace_real"/}"
  fi
  rm -f -- "$tmp"
}

# Run git from the workspace root under the scrub every Cargo stage
# gets. --no-optional-locks keeps 'status' from rewriting the index.
stamp_git() {
  (
    cd -- "$stamp_root" || exit
    build_scrub
    exec env "${scrub_args[@]}" git --no-optional-locks "$@"
  )
}

# Fail unless git reports nothing under the workspace root beyond what
# PHASE allows. Before the rewrite ('before'), only an untracked
# Cargo.lock: a release lane may restore a generated one, and Cargo
# never treats the lockfile as a dirty source. After it ('after'), only
# a change to a file the rewrite covered, whose content, mode and type
# stamp_recheck_tree compares with its copy; an untracked Cargo.lock
# then passes only that way, so one that appeared later does not.
# Anything else is a change Cargo would refuse to package, so passing
# --allow-dirty would hide it. Records are NUL-separated and paths
# compared whole, so a path holding a newline cannot pass for another.
stamp_check_tree() {
  local phase="$1" status_file="$work_dir/stamp.status" entry code path
  local allowed listed unexpected=0
  if ! stamp_git status --porcelain=v1 -z --untracked-files=all \
    --no-renames -- . > "$status_file"; then
    fail "git status failed in the workspace root"
  fi
  while IFS= read -r -d '' entry; do
    code="${entry:0:2}"
    path="${entry:3}"
    if [ "$phase" = "before" ] && [ "$code" = "??" ] \
      && [ "$path" = "$stamp_lock" ]; then
      continue
    fi
    listed=false
    if [ "$phase" = "after" ]; then
      for allowed in "${stamp_allowed[@]}"; do
        if [ "$allowed" = "$path" ]; then
          listed=true
        fi
      done
    fi
    if [ "$listed" = "true" ]; then
      case "$code" in
        " M" | "M " | "MM" | "??") continue ;;
      esac
    fi
    unexpected=$((unexpected + 1))
    # A non-blank prefix keeps a crafted path from reading as a
    # workflow command.
    printf 'Changed: %q (git status %q)\n' "$path" "$code"
  done < "$status_file"
  if [ "$unexpected" -gt 0 ]; then
    fail "version is set, but the checkout holds $unexpected change(s)" \
      "besides the version rewrite below the workspace root, listed in" \
      "the step log; Cargo would refuse to package them, so commit or" \
      "remove them"
  fi
}

# Re-check the checkout before each repackaging after verification,
# the upload included: crate code ran during verification, and
# --allow-dirty switches off Cargo's own check for a source it
# modified. git sees any other change; a rewritten file, which git
# already reports as modified, must still be a regular file with its
# stamped copy's content and executable bit.
stamp_recheck_tree() {
  local i exec_bit
  for i in "${!stamp_files[@]}"; do
    exec_bit=-
    if [ -x "${stamp_files[i]}" ]; then
      exec_bit=x
    fi
    if [ -L "${stamp_files[i]}" ] || [ ! -f "${stamp_files[i]}" ] \
      || [ "$exec_bit" != "${stamp_exec[i]}" ] \
      || ! cmp -s -- "$work_dir/stamp.$i" "${stamp_files[i]}"; then
      fail "${stamp_files[i]#"$workspace_real"/} changed after the" \
        "version rewrite"
    fi
  done
  if [ "${#dirty_args[@]}" -gt 0 ]; then
    stamp_check_tree after
    stamp_check_lock
  fi
}

# Fail when Cargo.lock exists but the rewrite did not cover it: crate
# code created it after the rewrite, and git may ignore it, so neither
# check above would see it, while --allow-dirty would package it.
stamp_check_lock() {
  local file
  if [ ! -e "$stamp_root/Cargo.lock" ] && [ ! -L "$stamp_root/Cargo.lock" ]; then
    return 0
  fi
  for file in "${stamp_files[@]}"; do
    if [ "$file" = "$stamp_root/Cargo.lock" ]; then
      return 0
    fi
  done
  fail "Cargo.lock appeared after the version rewrite; packaging it" \
    "needs --allow-dirty, which would let it through unchecked"
}

### Stamp version ###

stamp_version_stage() {
  local i file dir seen duplicate metadata_json
  local -a candidates=() files=()
  if [ -z "$version_input" ]; then
    return 0
  fi
  stage="Stamp version"

  # Guard: every member must carry the placeholder, so the stamped
  # version is the only one the release can carry.
  metadata_json="$(trusted_cargo metadata --no-deps --locked \
    --format-version 1 --manifest-path "$manifest_abs")"
  stamp_read_members "$metadata_json"
  for i in "${!stamp_names[@]}"; do
    if [ "${stamp_versions[i]}" != "$stamp_placeholder" ]; then
      version_cell="❌ $(summary_code "${stamp_names[i]}") carries"
      version_cell+=" $(summary_code "${stamp_versions[i]}"), not $(summary_code "$stamp_placeholder")"
      fail "version is set, so every workspace member must carry the" \
        "placeholder version $stamp_placeholder in Cargo.toml;" \
        "${stamp_names[i]} carries ${stamp_versions[i]}"
    fi
  done

  # The root manifest, each member's manifest once, and the lockfile,
  # each by its resolved path: cargo reports a member reached through a
  # symlinked directory by the link, which the containment checks must
  # see through.
  candidates=("$stamp_root/Cargo.toml" "${stamp_manifests[@]}")
  if [ -e "$stamp_root/Cargo.lock" ] || [ -L "$stamp_root/Cargo.lock" ]; then
    candidates+=("$stamp_root/Cargo.lock")
  fi
  for file in "${candidates[@]}"; do
    if [ ! -f "$file" ] || [ -L "$file" ]; then
      fail "version needs ${file#"$workspace_real"/} to be a regular" \
        "file, not missing or a symlink"
    fi
    dir="$(cd -- "$(dirname -- "$file")" && pwd -P)" \
      || fail "could not resolve ${file#"$workspace_real"/}"
    file="$dir/${file##*/}"
    require_within_workspace "every file the version rewrite changes" "$file"
    case "$file" in
      "$stamp_root"/*) ;;
      *) fail "version needs every member's manifest below the workspace root" ;;
    esac
    duplicate=false
    for seen in ${files[@]+"${files[@]}"}; do
      if [ "$seen" = "$file" ]; then
        duplicate=true
      fi
    done
    if [ "$duplicate" = "false" ]; then
      files+=("$file")
    fi
  done

  # Cargo refuses to package a modified checkout. When git sees one,
  # require it clean beforehand and its only changes the rewrite's
  # afterwards; then --allow-dirty lets exactly those through.
  # The trailing 'x' keeps a newline that ends the path.
  if stamp_top="$(stamp_git rev-parse --show-toplevel 2> /dev/null \
    && echo x)"; then
    stamp_top="${stamp_top%$'\n'x}"
  else
    stamp_top=""
  fi
  if [ -n "$stamp_top" ]; then
    stamp_allowed=()
    for file in "${files[@]}"; do
      case "$file" in
        "$stamp_top"/*) stamp_allowed+=("${file#"$stamp_top"/}") ;;
        *) fail "version needs the workspace inside its git work tree" ;;
      esac
    done
    stamp_lock="${stamp_root#"$stamp_top"}/Cargo.lock"
    stamp_lock="${stamp_lock#/}"
    stamp_check_tree before
  else
    stamp_top=""
    echo "git sees no work tree at the workspace root, so Cargo checks" \
      "the checkout itself and packages without --allow-dirty"
  fi

  for file in "${files[@]}"; do
    if [ "$file" = "$stamp_root/Cargo.lock" ]; then
      stamp_rewrite "$file" "$stamp_lock_awk" -v members="${stamp_names[*]}"
    else
      stamp_rewrite "$file" "$stamp_manifest_awk"
    fi
  done

  # Every member must now report the new version. A requirement the
  # rule rewrote by mistake fails here or in the next --locked call.
  metadata_json="$(trusted_cargo metadata --no-deps --locked \
    --format-version 1 --manifest-path "$manifest_abs")"
  stamp_read_members "$metadata_json"
  for i in "${!stamp_names[@]}"; do
    if [ "${stamp_versions[i]}" != "$version_input" ]; then
      version_cell="❌ $(summary_code "${stamp_names[i]}") reports"
      version_cell+=" $(summary_code "${stamp_versions[i]}") after the rewrite"
      fail "after the version rewrite, ${stamp_names[i]} reports" \
        "version ${stamp_versions[i]} rather than the version input"
    fi
  done

  stamp_files=("${files[@]}")
  stamp_exec=()
  for i in "${!stamp_files[@]}"; do
    cp -- "${stamp_files[i]}" "$work_dir/stamp.$i" \
      || fail "could not keep a copy of the version rewrite"
    if [ -x "${stamp_files[i]}" ]; then
      stamp_exec+=(x)
    else
      stamp_exec+=(-)
    fi
  done
  if [ -n "$stamp_top" ]; then
    stamp_check_tree after
    dirty_args=(--allow-dirty)
  fi
  version_cell="$(summary_cell "$version_input") (version input; Cargo.toml holds $stamp_placeholder)"
  echo "Stamped version $version_input into ${#stamp_names[@]} workspace" \
    "member(s) ✅"
}
