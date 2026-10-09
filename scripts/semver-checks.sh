#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Optional 'Check semver' stage for publish-crate.sh: compare the
# crate's public API with its latest earlier release on crates.io using
# cargo-semver-checks, so a breaking change cannot ship under a minor or
# patch version number.
#
# publish-crate.sh sources this file, calls semver_check_inputs while
# it checks inputs, and semver_check_stage once it knows whether
# crates.io already holds this version; workspace.sh calls
# semver_check_set at the same point for a set of workspace members,
# which checks each crate in turn. publish-crate.sh reads the stage's
# inputs and writes its outputs, so that one file holds the action's
# whole interface. Run directly, the file checks the version given as
# its argument alone, before action.yaml passes the version to
# taiki-e/install-action.
#
# The check compiles the crate and the published baseline, running
# their build scripts and procedural macros. It therefore refuses any
# run that holds publishing credentials, and every process it starts
# gets the environment scrub that publish-crate.sh's build_scrub gives
# every Cargo stage. The baseline comes from crates.io alone, so the
# check also refuses a named 'registry'.

# Globals shared with publish-crate.sh are assigned there (SC2154) or
# read there (SC2034).
# shellcheck disable=SC2154,SC2034

semver_cell="⏸️ Not reached"
semver_baseline=""
semver_home=""
semver_label=""
semver_exit=0
semver_reason=""
# In a set: the index of the crate under check, and each checked
# crate's state, baseline and summary text.
semver_index=""
semver_states=()
semver_baselines=()
semver_cells=()
semver_version_error="cargo_semver_checks_version must be a release version such as 0.51.0"

semver_version_valid() {
  [[ "$semver_tool_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# Names of the per-registry token variables in the environment. Cargo
# derives them from registry names, so they are valid identifiers.
semver_registry_token_vars() {
  local name
  for name in $(compgen -e); do
    case "$name" in
      CARGO_REGISTRIES_*_TOKEN) printf '%s\n' "$name" ;;
    esac
  done
}

# The Cargo home that cargo-semver-checks and its children use. As the
# compiling Package stage's Cargo would, the action resolves a relative
# CARGO_HOME against the project directory, and hands the check that
# absolute path. Empty when neither CARGO_HOME nor HOME is set.
semver_cargo_home() {
  local home="${CARGO_HOME:-${HOME:+$HOME/.cargo}}"
  case "$home" in
    "" | /*) ;;
    *) home="$project_dir/$home" ;;
  esac
  printf '%s' "$home"
}

# Print the physical form of an absolute path, followed by '/' so that
# a command substitution keeps any trailing newline: symlinks resolved
# along every directory that exists, and the missing remainder
# appended as Cargo would create it. Fails on a part that exists but
# is no reachable directory, such as a dangling symlink.
semver_physical_path() (
  local rest="${1#/}" part current=""
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    case "$rest" in
      */*) rest="${rest#*/}" ;;
      *) rest="" ;;
    esac
    case "$part" in
      "" | .) ;;
      ..) current="${current%/*}" ;;
      *)
        if cd -P -- "$current/$part" 2> /dev/null; then
          current="${PWD%/}"
        elif [ -e "$current/$part" ] || [ -L "$current/$part" ]; then
          return 1
        else
          current="$current/$part"
        fi
        ;;
    esac
  done
  printf '%s/' "$current"
)

# Settle the Cargo home the check uses. A CARGO_HOME inside the
# workspace would let checkout files reach the check's Cargo
# configuration, whose source replacement could swap a forged baseline
# in for crates.io. It counts as inside when its physical path does, so
# neither a relative value nor a symlink hides it. The check then gets
# that physical path. The default, ~/.cargo, stays as it is.
semver_settle_cargo_home() {
  local real
  semver_home="$(semver_cargo_home)"
  if [ -z "${CARGO_HOME:-}" ]; then
    return 0
  fi
  if ! real="$(semver_physical_path "$semver_home")"; then
    real="$workspace_real/"
  fi
  case "$real" in
    "$workspace_real"/*)
      fail "semver_checks needs CARGO_HOME to resolve outside the" \
        "workspace: Cargo reads source replacement from the Cargo home," \
        "so checkout files there could swap in a forged baseline. Set" \
        "CARGO_HOME outside GITHUB_WORKSPACE, or leave it unset."
      ;;
  esac
  semver_home="${real%/}"
  semver_home="${semver_home:-/}"
}

# Print why this run must not compile untrusted code, or nothing. The
# reason names inputs and variables, never their values. An empty
# variable carries no credential, so only non-empty ones count.
semver_credential_reason() {
  local name cargo_home="$semver_home"
  if [ "$dry_run" != "true" ]; then
    echo "publishes (dry_run is 'false')"
    return 0
  fi
  if [ -n "$expected_sha256" ]; then
    echo "is a publishing job (expected_sha256 is set)"
    return 0
  fi
  if [ -n "$registry_token" ]; then
    echo "holds registry_token"
    return 0
  fi
  for name in CARGO_REGISTRY_TOKEN $(semver_registry_token_vars) \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL; do
    if [ -n "${!name:-}" ]; then
      echo "has $name set"
      return 0
    fi
  done
  for name in credentials.toml credentials; do
    if [ -n "$cargo_home" ] && [ -e "$cargo_home/$name" ]; then
      echo "has a Cargo credentials file in CARGO_HOME"
      return 0
    fi
  done
}

# Called from publish-crate.sh while it checks inputs, before
# permit_fail takes effect: a refusal always fails the run.
semver_check_inputs() {
  local reason
  require_boolean semver_checks "$semver_checks"
  if [ "$semver_checks" != "true" ]; then
    return 0
  fi
  if ! semver_version_valid; then
    fail "$semver_version_error"
  fi
  semver_settle_cargo_home
  reason="$(semver_credential_reason)"
  if [ -n "$reason" ]; then
    fail "semver_checks compiles the crate and its published baseline," \
      "so it runs only in a dry run without publishing credentials;" \
      "this run $reason. Enable it in the unprivileged dry_run job."
  fi
  # Check inputs has already turned 'crates-io' into an empty registry.
  # A skip would leave a passing job that checked nothing.
  if [ -n "$registry" ]; then
    fail "semver_checks compares with a baseline from crates.io, the" \
      "only registry cargo-semver-checks supports, so it cannot check" \
      "a crate for a named registry; leave registry empty or" \
      "'crates-io', or set semver_checks to 'false'"
  fi
  if ! semver_tool_path="$(command -v cargo-semver-checks)"; then
    fail "required tool not found on PATH: cargo-semver-checks"
  fi
}


# Run cargo-semver-checks pinned to the resolved toolchain, building
# under the action's temporary directory, and with build_scrub's
# environment scrub. CARGO_HOME is passed as the absolute path that
# semver_settle_cargo_home settled and the credential refusal checked,
# whatever directory a child runs in.
#
# It runs from semver_dir, a fresh empty directory, with an absolute
# --manifest-path. The tool resolves crates.io through any source
# replacement in the Cargo configuration of its working directory, so
# from the project directory a checked-in .cargo/config.toml could
# substitute a forged baseline and fake a pass. It also runs directly
# rather than as 'cargo semver-checks': a Cargo alias in the checkout
# would otherwise shadow the external subcommand.
semver_tool() {
  local -a pin=()
  if [ -n "$toolchain_pin" ]; then
    pin=("RUSTUP_TOOLCHAIN=$toolchain_pin")
  fi
  if [ -n "$semver_home" ]; then
    pin+=("CARGO_HOME=$semver_home")
  fi
  (
    cd -- "$semver_dir" || exit
    build_scrub
    exec env "${scrub_args[@]}" CARGO_TARGET_DIR="$work_dir/semver-target" \
      ${pin[@]+"${pin[@]}"} "$semver_tool_path" semver-checks "$@"
  )
}

# Record the crate's state with semver_cell: one crate writes its
# output at once; a set keeps it for semver_set_outputs.
semver_record() {
  if [ -z "$semver_index" ]; then
    semver_output_status "$1"
    return 0
  fi
  semver_states[semver_index]="$1"
  semver_baselines[semver_index]="$semver_baseline"
  semver_cells[semver_index]="$semver_cell"
}

# A set's outputs map each checked crate to its state and baseline, as
# the set's other outputs do; the summary row lists every crate.
semver_set_outputs() {
  local i cell="" baselines
  baselines="$(set_json_map string "${semver_baselines[@]}")"
  if [ "$baselines" != "{}" ]; then
    semver_output_baseline "$baselines"
  fi
  semver_output_status "$(set_json_map string "${semver_states[@]}")"
  for i in "${!semver_cells[@]}"; do
    cell+="${cell:+; }$(summary_code "${set_names[i]}"): ${semver_cells[i]}"
  done
  semver_cell="$cell"
}

# Fail the stage once it has started, recording the failed state that
# the outputs and the summary report.
semver_fail() {
  semver_cell="❌ Could not run the check; see the step log"
  semver_record failed
  if [ -n "$semver_index" ]; then
    semver_set_outputs
  fi
  fail "$@"
}

semver_skip() {
  semver_cell="➖ Skipped: $2"
  semver_record skipped
  echo "::notice::Semver check skipped for $crate_name $crate_version: $1"
}

# Pick the baseline: the highest version on crates.io that is neither
# yanked nor a pre-release, and not above this one. A pre-release must
# stay strictly below its own release, which ranks above it. Leaves
# semver_baseline empty when no such version exists. Fails closed on
# any lookup error, and on a response that is empty or holds anything
# but index entries, which would otherwise read as a first release. An
# entry's version must follow the full SemVer 2.0.0 grammar: a
# malformed one that read as a pre-release would be dropped, and could
# leave no baseline, skipping the check instead of failing it.
semver_find_baseline() {
  local body="$work_dir/semver-index.json" code
  if [[ ! "$crate_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
    semver_fail "$crate_name version $crate_version is not a semantic version"
  fi
  if ! code="$(curl -sS --retry 3 -A "$user_agent" -o "$body" \
    -w '%{http_code}' "$index_url/$(index_path "$crate_name")")"; then
    semver_fail "could not reach the crates.io index for $crate_name"
  fi
  case "$code" in
    404) return 0 ;;
    200) ;;
    *) semver_fail "the crates.io index answered HTTP $code for $crate_name" ;;
  esac
  # Version components compare as (digit count, digits): exact at any
  # size, where numbers lose precision above 2^53 in some jq releases.
  # Neither side has leading zeros.
  if ! semver_baseline="$(jq -rn --arg current "$crate_version" '
    def parse: split("+")[0]
      | capture("^(?<core>[0-9]+[.][0-9]+[.][0-9]+)(?<pre>-.+)?$")
      | {key: (.core | split(".") | map([length, .])), pre: (.pre != null)};
    def semver: "(0|[1-9][0-9]*)" as $n
      | "(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)" as $pre
      | "[0-9A-Za-z-]+" as $build
      | "\\A\($n)[.]\($n)[.]\($n)(-\($pre)([.]\($pre))*)?"
        + "([+]\($build)([.]\($build))*)?\\z";
    def entry: if type == "object" and (.vers | type == "string")
        and (.vers | test(semver))
        and ((has("yanked") | not) or (.yanked | type == "boolean"))
      then . else error("not a crates.io index entry") end;
    ($current | parse) as $cur
    | [inputs | entry]
    | if length == 0 then error("no index entries") else . end
    | [.[] | select(.yanked != true) | .vers as $vers
       | $vers | parse | select(.pre | not)
       | select(if $cur.pre then .key < $cur.key else .key <= $cur.key end)
       | {key, vers: $vers}]
    | max_by(.key) | .vers // empty' "$body")"; then
    semver_baseline=""
    semver_fail "could not parse the crates.io index entry for $crate_name"
  fi
  if [ -n "$semver_baseline" ] \
    && [[ ! "$semver_baseline" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+[0-9A-Za-z.-]+)?$ ]]; then
    semver_baseline=""
    semver_fail "the crates.io index lists an unexpected version for $crate_name"
  fi
}

# Prepare the tool once, when the first crate needs it: its working
# directory and its version, which the summary names.
semver_prepare() {
  local tool
  if [ -n "$semver_label" ]; then
    return 0
  fi
  # A path toolchain is the project's own: rustup finds it only from
  # the project directory, and the action has already warned about it.
  semver_dir="$project_dir"
  if [ "$toolchain_kind" != "path" ]; then
    semver_dir="$work_dir/semver-cwd"
    if ! mkdir "$semver_dir"; then
      semver_fail "could not prepare the semver check's directory"
    fi
  fi

  if ! tool="$(semver_tool --version)"; then
    semver_fail "cargo-semver-checks --version failed"
  fi
  tool="${tool%%$'\n'*}"
  if [[ ! "$tool" =~ ^cargo-semver-checks\ [0-9A-Za-z.+-]+$ ]]; then
    tool="cargo-semver-checks"
  fi
  semver_label="$tool"
}

# Check crate_name at crate_version, whose manifest is $1, given the
# registry_status that the crates.io check found. Sets semver_exit to
# the tool's exit status (0 for a pass or a skip) and, on a failure,
# semver_reason. It returns normally, so the caller's errexit stays in
# force inside it.
semver_check_crate() {
  local manifest="$1" log="$work_dir/semver-checks.log" status=0
  local lints="" lint
  semver_exit=0
  semver_baseline=""
  # The publishing job would skip this exact archive, so nothing new
  # could ship.
  if [ "$registry_status" = "identical" ]; then
    semver_skip "this exact archive is already on crates.io" \
      "identical archive already on crates.io"
    return 0
  fi
  semver_find_baseline
  if [ -z "$semver_baseline" ]; then
    semver_skip "crates.io holds no earlier release to compare with" \
      "no earlier release on crates.io"
    return 0
  fi
  if [ -z "$semver_index" ]; then
    semver_output_baseline "$semver_baseline"
  fi

  semver_prepare
  echo "Checking $crate_name $crate_version against $semver_baseline" \
    "from crates.io with $semver_label"
  semver_tool check-release --manifest-path "$manifest" \
    --package "$crate_name" --baseline-version "$semver_baseline" \
    --color never 2>&1 | tee "$log" || status=$?

  if [ "$status" -eq 0 ]; then
    semver_cell="✅ Compatible with $(summary_code "$semver_baseline") ($(summary_cell "$semver_label"))"
    semver_record passed
    echo "$crate_name $crate_version is semver-compatible with $semver_baseline ✅"
    return 0
  fi

  # cargo-semver-checks exits 100 when lints fail; anything else is an
  # error running it. Lint names are restricted to a safe character set
  # before they reach the summary.
  if [ "$status" -eq 100 ]; then
    while IFS= read -r lint; do
      lints="${lints:+$lints, }$(summary_code "$lint")"
    done < <(sed -n 's/^--- failure \([a-z0-9_]\{1,80\}\): .*/\1/p' "$log" | sort -u)
    semver_cell="❌ Breaking changes against $(summary_code "$semver_baseline")${lints:+: $lints}"
    semver_reason="cargo-semver-checks found changes in $crate_name $crate_version that its version number does not allow, compared with $semver_baseline; see the step log."
  else
    semver_cell="❌ cargo-semver-checks failed (exit $status)"
    semver_reason="cargo-semver-checks failed with exit status $status for $crate_name $crate_version; see the step log."
    if [ -z "$semver_index" ]; then
      semver_reason="cargo-semver-checks failed with exit status $status; see the step log."
    fi
  fi
  semver_record failed
  semver_exit="$status"
}

semver_check_stage() {
  if [ "$semver_checks" != "true" ]; then
    return 0
  fi
  stage="Check semver"
  semver_check_crate "$manifest_abs"
  if [ "$semver_exit" -ne 0 ]; then
    failure_reason="$semver_reason"
    echo "::error::$failure_reason"
    exit "$semver_exit"
  fi
}

# Called by workspace.sh for a set of two or more crates, once the
# crates.io check has recorded each crate's state. Each crate is
# checked against its own latest earlier release on crates.io, from
# its own manifest; a crate without one skips with a notice. A crate
# that fails does not stop the others, so one run reports every
# breaking change; the run then fails with the first failure's exit
# status. An index or tool error still fails at once.
semver_check_set() {
  local i first=0 reasons=""
  if [ "$semver_checks" != "true" ]; then
    return 0
  fi
  stage="Check semver"
  for i in "${!set_names[@]}"; do
    semver_index="$i"
    crate_name="${set_names[i]}"
    crate_version="${set_versions[i]}"
    registry_status="${set_registry[i]}"
    semver_check_crate "${set_manifests[i]}"
    if [ "$semver_exit" -ne 0 ]; then
      echo "::error::$semver_reason"
      reasons="${reasons:+$reasons }$semver_reason"
      if [ "$first" -eq 0 ]; then
        first="$semver_exit"
      fi
    fi
  done
  semver_set_outputs
  if [ "$first" -ne 0 ]; then
    failure_reason="$reasons"
    exit "$first"
  fi
}

# Run directly: check the version before the action installs it.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  semver_tool_version="${1-}"
  if ! semver_version_valid; then
    echo "::error::$semver_version_error"
    exit 1
  fi
fi
