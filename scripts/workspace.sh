#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Workspace publishing helpers, sourced by publish-crate.sh.
#
# 'workspace' and 'packages' select crates from 'cargo metadata'; the
# selection runs in dependency order. One selected crate takes
# publish-crate.sh's single-crate path, so its outputs keep their
# shape. Several go through publish_crate_set below, which hands the
# whole set to each Cargo command as '-p' arguments: Cargo then
# packages every member against the others' fresh archives, so a crate
# whose sibling dependency is not on the registry yet still packages
# and verifies, and the archives match the ones a later upload builds.
# Every Cargo call, index lookup and the upload's token handling go
# through publish-crate.sh's registry-aware helpers and settings, so a
# set targets the registry the 'registry' input names, as one crate
# does.

# The state and helpers used here belong to publish-crate.sh, which is
# linted with this file sourced.
# shellcheck disable=SC2034,SC2154

set_names=()
set_versions=()
set_manifests=()
set_sizes=()
set_digests=()
set_registry=()
set_status=()
set_skipped=""
set_mode="false"

# Split a whitespace-separated list into the words array.
split_words() {
  words=()
  read -r -d '' -a words <<< "$1" || true
}

json_strings() {
  jq -cn '$ARGS.positional' --args "$@"
}

# Print a compact JSON object mapping each selected crate, in publish
# order, to the value at its index among the remaining arguments,
# leaving out crates without one. Kind 'number' emits numbers.
set_json_map() {
  local kind="$1" i
  shift
  local -a values=("$@") pairs=()
  for i in "${!set_names[@]}"; do
    if [ -n "${values[i]-}" ]; then
      pairs+=("${set_names[i]}" "${values[i]}")
    fi
  done
  jq -cn --arg kind "$kind" '$ARGS.positional as $a
    | reduce range(0; $a | length; 2) as $i ({};
        . + {($a[$i]): (if $kind == "number" then ($a[$i + 1] | tonumber)
                        else $a[$i + 1] end)})' \
    --args ${pairs[@]+"${pairs[@]}"}
}

# expected_sha256 holds a digest map when it opens with '{'.
expected_is_map() {
  local trimmed="${expected_sha256#"${expected_sha256%%[![:space:]]*}"}"
  [[ "$trimmed" == "{"* ]]
}

# A map must be one JSON object of crate names to lowercase SHA-256
# digests, without repeated keys, which jq would otherwise collapse
# silently. Prints the map in compact form.
parse_digest_map() {
  local map
  map="$(jq -ces 'select(length == 1) | .[0]
    | select(type == "object" and length > 0
      and all(keys[]; test("^[A-Za-z0-9_-]+$"))
      and all(.[]; type == "string" and test("^[0-9a-f]{64}$")))' \
    <<< "$expected_sha256" 2> /dev/null)" || return 1
  jq -en --stream '[inputs | select(length == 2) | .[0][0]]
    | length == (unique | length)' <<< "$expected_sha256" \
    > /dev/null 2>&1 || return 1
  printf '%s' "$map"
}

# Check that a digest map names exactly the selected crates.
require_digest_keys() {
  if ! jq -e --argjson names "$(json_strings "$@")" \
    'keys == ($names | sort)' <<< "$expected_sha256" > /dev/null; then
    fail "expected_sha256 must name exactly the selected crates:" \
      "$*"
  fi
}

# Order a JSON array of {name, deps} so every crate follows the
# selected crates it depends on. As in Cargo's own upload plan, crates
# go in rounds: each round holds, sorted by name, every crate whose
# dependencies came in earlier rounds. Fails on a cycle, which Cargo
# refuses to package too.
order_crates() {
  jq -c 'def order:
      if length == 0 then []
      else (map(select(.deps | length == 0)) | map(.name) | sort) as $ready
        | if ($ready | length) == 0 then error("cycle")
          else $ready + (map(select(.name | IN($ready[]) | not)
            | .deps -= $ready) | order)
          end
      end;
    map(.name) as $names
    | . as $crates
    | map(.deps |= map(select(IN($names[]))))
    | order
    | map(. as $name | $crates[] | select(.name == $name))' "$1"
}

# Select crates from the metadata held in $metadata, as Cargo would for
# 'packages' (-p each) or 'workspace' (--workspace, less 'exclude'),
# keep those the target registry accepts, and fill the set_* arrays in
# dependency order. As Cargo does, a package.publish list must name
# that registry exactly: 'my_reg' does not match 'my-reg', although
# both read CARGO_REGISTRIES_MY_REG_*. Metadata reports publish = false
# as [] and an absent or true setting as null.
select_crates() {
  local mode="$1" members="$work_dir/members.json"
  local selected="$work_dir/selected.json" ordered="$work_dir/ordered.json"
  local word name version manifest
  # A packaged manifest keeps dev dependencies that carry a version.
  # Metadata reports an unversioned one as req "*", the same as an
  # explicit version = "*", so the latter is not counted as an edge.
  # crates.io refuses any wildcard requirement, and Cargo still rejects
  # a cycle through one while packaging, before any upload. An edge
  # needs the dependency's path to be a member's directory: a path
  # crate outside the workspace may share a member's name. A
  # version-only dependency that [patch] points at a member is no edge
  # either: Cargo packages it against the crates.io release and does
  # not order the upload by it, so the resolve graph would misreport.
  # Reading that graph would also download every dependency.
  if ! jq -c --arg registry "$publish_registry" '.workspace_members as $ids
    | [.packages[] | select(.id | IN($ids[]))] as $member_pkgs
    | ($member_pkgs | map({key: (.manifest_path | sub("/Cargo\\.toml$"; "")),
        value: .name}) | from_entries) as $dirs
    | [$member_pkgs[]
       | {name, version, manifest_path,
          publishable: (.publish == null
            or any(.publish[]; . == $registry)),
          deps: [(.dependencies // [])[]
            | select(.path != null and (.kind != "dev" or .req != "*"))
            | $dirs[.path] // empty] | unique}]' <<< "$metadata" > "$members" 2> /dev/null \
    || ! jq -e 'length > 0 and all(.[];
      (.name | type == "string" and test("^[A-Za-z0-9_-]+$"))
      and (.version | type == "string" and test("^[0-9A-Za-z.+-]+$"))
      and (.manifest_path | type == "string"))' "$members" > /dev/null; then
    fail "cargo metadata returned unexpected workspace members"
  fi

  if [ "$mode" = "packages" ]; then
    for word in "${packages[@]}"; do
      if ! jq -e --arg n "$word" 'any(.[]; .name == $n)' "$members" > /dev/null; then
        fail "packages names $word, which is not a member of this workspace"
      fi
      if ! jq -e --arg n "$word" 'any(.[]; .name == $n and .publishable)' \
        "$members" > /dev/null; then
        fail "packages names $word, whose package.publish setting" \
          "excludes $registry_label"
      fi
    done
    jq -c --argjson named "$(json_strings "${packages[@]}")" \
      'map(select(.name | IN($named[])))' "$members" > "$selected"
  else
    for word in ${excludes[@]+"${excludes[@]}"}; do
      if ! jq -e --arg n "$word" 'any(.[]; .name == $n)' "$members" > /dev/null; then
        warn "exclude names $word, which is not a member of this workspace"
      fi
    done
    jq -c --argjson excluded "$(json_strings ${excludes[@]+"${excludes[@]}"})" \
      'map(select(.name | IN($excluded[]) | not))' "$members" > "$selected"
    set_skipped="$(jq -r 'map(select(.publishable | not) | .name)
      | sort | join(", ")' "$selected")"
    if [ -n "$set_skipped" ]; then
      echo "::notice::Skipping workspace members whose package.publish" \
        "setting excludes $registry_label: $set_skipped"
    fi
    jq -c 'map(select(.publishable))' "$selected" > "$selected.tmp"
    mv -- "$selected.tmp" "$selected"
  fi
  if ! jq -e 'length > 0' "$selected" > /dev/null; then
    fail "the selection holds no crate that can be published to" \
      "$registry_label"
  fi
  if ! order_crates "$selected" > "$ordered" 2> /dev/null; then
    fail "the selected crates depend on each other in a cycle"
  fi

  while IFS=$'\t' read -r name version manifest; do
    if [ ! -f "$manifest" ] || [ -L "$manifest" ]; then
      fail "cargo metadata named a manifest for $name that is missing" \
        "or a symlink"
    fi
    require_within_workspace "the manifest of $name" "$manifest"
    set_names+=("$name")
    set_versions+=("$version")
    set_manifests+=("$manifest")
  done < <(jq -r '.[] | [.name, .version, .manifest_path] | @tsv' "$ordered")
  echo "Selected crates, in publish order: ${set_names[*]}"
}

# Cargo 1.90 stabilised publishing several packages in one command.
require_set_cargo() {
  if [[ ! "$cargo_version" =~ ^([0-9]+)\.([0-9]+)\. ]] \
    || [ "${BASH_REMATCH[1]}" -lt 1 ] \
    || { [ "${BASH_REMATCH[1]}" -eq 1 ] && [ "${BASH_REMATCH[2]}" -lt 90 ]; }; then
    fail "publishing several crates needs Cargo 1.90 or later; this" \
      "toolchain has cargo $cargo_version"
  fi
}

# One job summary row per crate of the set.
set_summary_rows() {
  local i state details
  for i in "${!set_names[@]}"; do
    case "${set_status[i]-}" in
      published) state="🚀 Published" ;;
      skipped)
        state="⛔️ Skipped: identical archive already on"
        state+=" $(summary_cell "$registry_label")"
        ;;
      dry-run) state="✅ Dry run passed" ;;
      failed) state="❌ Not published" ;;
      *) state="⏸️ Not reached" ;;
    esac
    details=""
    if [ -n "${set_sizes[i]-}" ]; then
      if [ "${set_sizes[i]}" -gt "$max_bytes" ]; then
        details+="; ❌ $(human_bytes "${set_sizes[i]}"), over the"
        details+=" $(human_bytes "$max_bytes") limit"
      else
        details+="; $(human_bytes "${set_sizes[i]}")"
      fi
    fi
    case "${set_registry[i]-}:${set_status[i]-}" in
      absent:published) ;;
      absent:*) details+="; not yet on $(summary_cell "$registry_label")" ;;
      identical:dry-run)
        details+="; already on $(summary_cell "$registry_label"),"
        details+=" identical archive"
        ;;
      different:*)
        details+="; ⚠️ $(summary_cell "$registry_label") holds different"
        details+=" content"
        ;;
    esac
    if [ -n "${set_digests[i]-}" ]; then
      details+="; $(summary_code "${set_digests[i]}")"
    fi
    # As for one crate, only crates.io has a known page to link.
    if [ -z "$registry" ]; then
      case "${set_status[i]-}" in
        published | skipped)
          details+="; 🔗 https://crates.io/crates/${set_names[i]}/${set_versions[i]}"
          ;;
      esac
    fi
    summary_row "$(summary_code "${set_names[i]} ${set_versions[i]}")" \
      "$state$details"
  done
}

# Check, package and publish every crate of the set together. Each
# stage covers the whole set before the next starts, as for one crate.
publish_crate_set() {
  local i file count="${#set_names[@]}" upload_status=0 tag_version
  local -a select_args=() remaining=() remaining_args=() remaining_names=()
  local -a uploaded=()
  set_mode="true"
  require_set_cargo
  crate_name="${set_names[*]}"
  write_output crate_name "$crate_name"
  write_output crate_version "$(set_json_map string "${set_versions[@]}")"
  for i in "${!set_names[@]}"; do
    select_args+=(-p "${set_names[i]}")
  done

  stage="Verify release tag"
  if [ -n "$release_tag" ]; then
    tag_version="${release_tag#v}"
    for i in "${!set_names[@]}"; do
      if [ "${set_versions[i]}" != "$tag_version" ]; then
        tag_cell="❌ $(summary_code "$release_tag") does not match"
        tag_cell+=" $(summary_code "${set_names[i]} ${set_versions[i]}")"
        fail "${set_names[i]} Cargo.toml version (${set_versions[i]})" \
          "does not match release tag ($tag_version); every selected" \
          "crate must carry the tag's version"
      fi
    done
    tag_cell="✅ $(summary_code "$release_tag") matches all $count crates"
    echo "All $count crates match release tag $release_tag ✅"
  fi

  stage="Package"
  if [ -n "$expected_sha256" ]; then
    trusted_cargo package --no-verify --locked \
      ${package_registry[@]+"${package_registry[@]}"} \
      --target-dir "$package_target" --manifest-path "$manifest_abs" \
      "${select_args[@]}"
    verification_cell="⏸️ Awaiting digest match"
  else
    cargo_with_annotations project_cargo package --locked \
      ${package_registry[@]+"${package_registry[@]}"} \
      --target-dir "$package_target" --manifest-path "$manifest_abs" \
      "${select_args[@]}"
    verification_cell="✅ Compiled and verified in this job"
  fi

  stage="Check package size"
  for i in "${!set_names[@]}"; do
    file="$package_target/package/${set_names[i]}-${set_versions[i]}.crate"
    if [ ! -f "$file" ]; then
      fail "cargo package did not produce" \
        "${set_names[i]}-${set_versions[i]}.crate"
    fi
    set_sizes[i]="$(wc -c < "$file")"
    set_sizes[i]="${set_sizes[i]//[[:space:]]/}"
    set_digests[i]="$(sha256_of "$file")"
    echo "${set_names[i]} package: ${set_sizes[i]} bytes," \
      "SHA-256 ${set_digests[i]}"
  done
  write_output crate_size_bytes "$(set_json_map number "${set_sizes[@]}")"
  write_output crate_sha256 "$(set_json_map string "${set_digests[@]}")"
  for i in "${!set_names[@]}"; do
    if [ "${set_sizes[i]}" -gt "$max_bytes" ]; then
      fail "${set_names[i]} package is ${set_sizes[i]} bytes, exceeding" \
        "the $max_bytes-byte limit"
    fi
  done

  if [ -n "$expected_sha256" ]; then
    stage="Match verified digest"
    for i in "${!set_names[@]}"; do
      if [ "${set_digests[i]}" != "$(jq -r --arg n "${set_names[i]}" \
        '.[$n]' <<< "$expected_sha256")" ]; then
        verification_cell="❌ $(summary_code "${set_names[i]}") differs"
        verification_cell+=" from the verified digest"
        fail "${set_names[i]} package does not match its" \
          "expected_sha256 entry; not publishing. This job packaged it" \
          "with cargo $cargo_version; if the verifying job's" \
          "cargo_version output differs, pin an exact toolchain channel."
      fi
    done
    verification_cell="✅ Matches the digests from an earlier job; not"
    verification_cell+=" compiled here"
    echo "Every package matches its expected_sha256 entry ✅"
  fi

  # As for one crate: identical bytes on the registry mean a re-run, so
  # that crate is skipped and the rest resume; different bytes fail a
  # release before anything uploads.
  stage="Check $registry_label"
  for i in "${!set_names[@]}"; do
    crate_name="${set_names[i]}"
    crate_version="${set_versions[i]}"
    crate_sha256="${set_digests[i]}"
    query_registry
    set_registry[i]="$registry_status"
    case "$registry_status" in
      identical)
        if [ "$dry_run" = "false" ]; then
          set_status[i]="skipped"
          echo "$crate_name $crate_version is already on $registry_label" \
            "with identical content; skipping its upload ⛔️"
          continue
        fi
        ;;
      different)
        if [ "$release_intent" = "true" ]; then
          write_output registry_status \
            "$(set_json_map string "${set_registry[@]}")"
          fail "$crate_name $crate_version is already on $registry_label" \
            "with different content (published SHA-256" \
            "$published_sha256). $replace_note"
        fi
        warn "$crate_name $crate_version is already on $registry_label" \
          "with different content; bump the version before releasing."
        ;;
    esac
    remaining+=("$i")
    remaining_args+=(-p "$crate_name")
    remaining_names+=("$crate_name")
  done
  write_output registry_status "$(set_json_map string "${set_registry[@]}")"
  if [ "${#remaining[@]}" -eq 0 ]; then
    publish_status="skipped"
    echo "Every selected crate is already on $registry_label; nothing" \
      "to upload"
    return 0
  fi

  # Opt-in, and only in a dry run, which keeps every crate above.
  semver_check_set

  stage="Dry-run publish"
  cargo_with_annotations trusted_cargo publish --dry-run --no-verify --locked \
    --registry "$publish_registry" --target-dir "$package_target" \
    --manifest-path "$manifest_abs" "${remaining_args[@]}"

  stage="Confirm package unchanged"
  trusted_cargo package --no-verify --locked \
    ${package_registry[@]+"${package_registry[@]}"} \
    --target-dir "$package_target" --manifest-path "$manifest_abs" \
    "${select_args[@]}"
  for i in "${!set_names[@]}"; do
    file="$package_target/package/${set_names[i]}-${set_versions[i]}.crate"
    if [ ! -f "$file" ] || [ "$(sha256_of "$file")" != "${set_digests[i]}" ]; then
      fail "${set_names[i]} package changed after verification; not" \
        "publishing"
    fi
  done

  if [ "$dry_run" = "true" ]; then
    for i in "${!set_names[@]}"; do
      set_status[i]="dry-run"
    done
    echo "Dry run: $count crates validated, not published ✅"
    return 0
  fi

  # Cargo uploads the set in dependency order, waiting for each crate
  # to reach the index before the next. publishing_cargo hands the
  # token to the target registry's variables alone.
  stage="Publish"
  crate_name="${remaining_names[*]}"
  describe_trusted_publisher
  publishing_cargo publish --no-verify --locked --registry "$publish_registry" \
    --target-dir "$package_target" --manifest-path "$manifest_abs" \
    "${remaining_args[@]}" || upload_status=$?
  if [ "$upload_status" -eq 0 ]; then
    for i in "${remaining[@]}"; do
      set_status[i]="published"
    done
    published="true"
    publish_status="published"
    echo "Published ${#remaining[@]} crates to $registry_label ✅"
    return 0
  fi

  # Some crates may have reached the registry before the failure. Each one
  # the index shows with these bytes counts as published, so a re-run
  # skips it and resumes with the rest. Whatever a lookup finds replaces
  # the state seen before the upload; a failed lookup leaves that state.
  for i in "${remaining[@]}"; do
    crate_name="${set_names[i]}"
    crate_version="${set_versions[i]}"
    crate_sha256="${set_digests[i]}"
    set_status[i]="failed"
    if lookup_registry; then
      set_registry[i]="$registry_status"
      if [ "$registry_status" = "identical" ]; then
        set_status[i]="published"
        uploaded+=("$crate_name")
        published="true"
      fi
    fi
  done
  write_output registry_status "$(set_json_map string "${set_registry[@]}")"
  if [ "${#uploaded[@]}" -eq "${#remaining[@]}" ]; then
    publish_status="published"
    warn "cargo publish failed, but $registry_label holds every remaining" \
      "archive; treating them as published."
    return 0
  fi
  failure_reason="cargo publish failed with exit status $upload_status"
  failure_reason+=" after uploading ${#uploaded[@]} of ${#remaining[@]}"
  failure_reason+=" crates. A re-run skips the uploaded ones and resumes."
  echo "::error::$failure_reason"
  exit "$upload_status"
}
