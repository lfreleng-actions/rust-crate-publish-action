<!--
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Overture Maps
# SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

# 🦀 Rust Crate Publish Action

<!-- prettier-ignore-start -->
<!-- markdownlint-disable-next-line MD013 -->
[![Linux Foundation](https://img.shields.io/badge/Linux-Foundation-blue)](https://linuxfoundation.org/) [![Source Code](https://img.shields.io/badge/GitHub-100000?logo=github&logoColor=white&color=blue)](https://github.com/lfreleng-actions/rust-crate-publish-action) [![License](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT) [![pre-commit.ci status badge]][pre-commit.ci results page] [![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/lfreleng-actions/rust-crate-publish-action/badge)](https://scorecard.dev/viewer/?uri=github.com/lfreleng-actions/rust-crate-publish-action)
<!-- prettier-ignore-end -->

Packages a Rust crate, checks its size against the crates.io upload cap,
verifies its version against a release tag, and publishes it to
crates.io or another Cargo registry.

This action builds on John McCall's `publish-crate-to-crates-io` action
for Overture Maps; see [Acknowledgements](#acknowledgements).

## rust-crate-publish-action

By default the action publishes the one crate `manifest_path` names,
as v0.0.1 did. With `workspace` or `packages` it publishes two or more
workspace members in one call, in dependency order; see
[Workspaces](#workspaces). It targets crates.io unless `registry`
names another Cargo registry, such as
[staging.crates.io](https://staging.crates.io), and suits
[Trusted Publishing](https://crates.io/docs/trusted-publishing), where
the calling workflow exchanges a GitHub OIDC token for a short-lived
crates.io token. The action never requests OIDC tokens itself: the
caller owns authentication, token scope and environment configuration.

## Usage Example

Verify in one job and publish from another. The `verify` job compiles
the crate with no credentials in reach. The `publish` job holds the
token but compiles nothing: given `expected_sha256`, it refuses any
archive that differs from the one `verify` checked. See
[Credential handling](#credential-handling) for why this separation
matters.

<!-- markdownlint-disable MD013 MD046 -->

```yaml
on:
  release:
    types: [published]

permissions: {}

jobs:
  verify:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    outputs:
      crate_sha256: ${{ steps.verify.outputs.crate_sha256 }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - name: "Verify crate"
        id: verify
        uses: lfreleng-actions/rust-crate-publish-action@main
        with:
          release_tag: ${{ github.event.release.tag_name }}
          dry_run: 'true'

  publish:
    needs: verify
    runs-on: ubuntu-latest
    # Must match the crate's Trusted Publisher configuration
    environment: crates-io
    permissions:
      contents: read
      id-token: write  # Mint the OIDC token crates.io exchanges
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - name: "Authenticate with crates.io"
        id: auth
        uses: rust-lang/crates-io-auth-action@c6f97d42243bad5fab37ca0427f495c86d5b1a18 # v1.0.5

      - name: "Publish crate"
        uses: lfreleng-actions/rust-crate-publish-action@main
        with:
          release_tag: ${{ github.event.release.tag_name }}
          registry_token: ${{ steps.auth.outputs.token }}
          expected_sha256: ${{ needs.verify.outputs.crate_sha256 }}
```

<!-- markdownlint-enable MD013 MD046 -->

### Check packaging on every pull request

A dry run needs no credentials, no `id-token` permission and no
environment:

<!-- markdownlint-disable MD013 MD046 -->

```yaml
steps:
  - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
    with:
      persist-credentials: false

  - name: "Check crate packaging"
    uses: lfreleng-actions/rust-crate-publish-action@main
    with:
      dry_run: 'true'
```

<!-- markdownlint-enable MD013 MD046 -->

### Check semver compatibility before release

Add `semver_checks` to the unprivileged `verify` job. It compares the
crate's public API with the latest earlier release on crates.io and
fails the job when the version number does not allow the change, so
`publish` never runs. The `publish` job must leave it unset: the
action refuses it there. See [Semver checks](#semver-checks).

<!-- markdownlint-disable MD013 MD046 -->

```yaml
      - name: "Verify crate"
        id: verify
        uses: lfreleng-actions/rust-crate-publish-action@main
        with:
          release_tag: ${{ github.event.release.tag_name }}
          dry_run: 'true'
          semver_checks: 'true'
```

<!-- markdownlint-enable MD013 MD046 -->

### Publish workspace members in dependency order

Set `workspace` to `true` to publish every member that crates.io
accepts, or list members in `packages`. The two-job pattern above works
for a workspace too: `crate_sha256` becomes a JSON object of crate
names to digests, which `expected_sha256` accepts as it stands.
Cargo packages the whole selection as one set, so a member whose
sibling dependency is not on crates.io yet still verifies. Crates.io
must list a Trusted Publisher for each crate.

<!-- markdownlint-disable MD013 MD046 -->

```yaml
# In the verify job
- name: "Verify workspace crates"
  id: verify
  uses: lfreleng-actions/rust-crate-publish-action@main
  with:
    workspace: 'true'
    release_tag: ${{ github.event.release.tag_name }}
    dry_run: 'true'

# In the publish job, after authenticating
- name: "Publish workspace crates"
  uses: lfreleng-actions/rust-crate-publish-action@main
  with:
    workspace: 'true'
    release_tag: ${{ github.event.release.tag_name }}
    registry_token: ${{ steps.auth.outputs.token }}
    expected_sha256: ${{ needs.verify.outputs.crate_sha256 }}
```

<!-- markdownlint-enable MD013 MD046 -->

Calling the action once per member, each selected by
`manifest_path`, also still works, one crate at a time: Cargo
packages a lone crate against crates.io, so it cannot package a
dependent crate until the dependency version it needs is there.
Chain those calls with `needs`, or run them in order in one job.
Either way Cargo cannot verify a crate until the crates it depends
on reach crates.io, so verifying the whole set before anything
publishes needs the workspace inputs above.

### Publish to another Cargo registry

Set `registry` to a registry name (as Cargo requires, a letter or `_`
first, then letters, digits, `_` or `-`), and its sparse index URL in
`CARGO_REGISTRIES_<NAME>_INDEX`, where `<NAME>` is the name in upper
case with `-` as `_`. The action then passes `--registry <name>` to
every `cargo package` and `cargo publish` call, checks the version
against that registry's index, and hands `registry_token` to the
upload alone as `CARGO_REGISTRIES_<NAME>_TOKEN`. With `registry_token`
empty, the upload uses the caller's `CARGO_REGISTRIES_<NAME>_TOKEN`; a
crates.io token never reaches it.

The crates.io staging site accepts Trusted Publishing.
`rust-lang/crates-io-auth-action` reaches it through its `url` input,
and both jobs must name the same registry, since Cargo packages for
the registry it targets:

<!-- markdownlint-disable MD013 MD046 -->

```yaml
jobs:
  verify:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    env:
      CARGO_REGISTRIES_STAGING_INDEX: "sparse+https://index.staging.crates.io/"
    outputs:
      crate_sha256: ${{ steps.verify.outputs.crate_sha256 }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - name: "Verify crate"
        id: verify
        uses: lfreleng-actions/rust-crate-publish-action@main
        with:
          registry: staging
          dry_run: 'true'

  publish:
    needs: verify
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write  # Mint the OIDC token staging.crates.io exchanges
    env:
      CARGO_REGISTRIES_STAGING_INDEX: "sparse+https://index.staging.crates.io/"
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - name: "Authenticate with staging.crates.io"
        id: auth
        uses: rust-lang/crates-io-auth-action@c6f97d42243bad5fab37ca0427f495c86d5b1a18 # v1.0.5
        with:
          url: "https://staging.crates.io"

      - name: "Publish crate to staging"
        uses: lfreleng-actions/rust-crate-publish-action@main
        with:
          registry: staging
          registry_token: ${{ steps.auth.outputs.token }}
          expected_sha256: ${{ needs.verify.outputs.crate_sha256 }}
```

<!-- markdownlint-enable MD013 MD046 -->

Staging keeps its own accounts, crates and Trusted Publisher
configurations, apart from crates.io. As on crates.io, the first
version of a crate needs an API token; configure the Trusted Publisher
after that.

A named registry must offer:

- A sparse index over HTTPS (`sparse+https://`, ending in `/` as Cargo
  requires), which the action reads for the version check. It refuses
  git indexes, and index or `api` URLs without a host, with a query or
  fragment, or with credentials in them (`https://user:secret@...`),
  which would reach the job log.
- An index anyone can read: it refuses `auth-required` registries,
  since the upload alone holds a token.
- An HTTPS `api` URL in the index's `config.json`, where Cargo
  uploads.

The action has no built-in name for staging. A reserved name would
send the token to crates.io staging whenever a caller forgot to set
the index of a registry of their own called `staging`; setting the
index keeps the destination explicit. `crates-io`, Cargo's own name
for crates.io, means the same as an empty `registry`.

## Requirements

- Bash, `cargo`, `jq`, `curl`, `mktemp`, and `sha256sum` or `shasum`
  on the runner. GitHub-hosted runners include them; the action
  fails with a clear error naming any missing tool.
- A rustup channel toolchain, if the project selects one through a
  `rust-toolchain` file. The action refuses to upload with a
  path-based toolchain; see
  [Toolchain and configuration](#toolchain-and-configuration). For the
  two-job pattern, pin an exact channel such as `1.98.1`, because
  different Cargo versions package the same sources differently.
- A clean git checkout. Cargo refuses to package files that git
  reports as uncommitted.
- A committed `Cargo.lock` for crates with dependencies, since every
  Cargo stage runs with `--locked`.
- Cargo 1.90 or later to publish two or more crates in one call. A
  single crate needs nothing newer than its manifest does.
- Network access to `index.crates.io` for the version check and the
  dry run, plus `static.crates.io` to download dependencies and
  `crates.io` to publish. Block-mode egress policies must admit these
  hosts; the `lfreleng-actions` allow-list does from v0.16.3. A named
  registry needs its index host, its `dl` host when the crate has
  dependencies there, and its `api` host to publish. For staging
  these are `index.staging.crates.io`, `static.staging.crates.io` and
  `staging.crates.io`.
- For `semver_checks`, a toolchain that `cargo-semver-checks` supports:
  the default version, 0.51.0, needs Rust 1.93 or newer. It also
  downloads the tool from GitHub releases (`github.com` and
  `*.githubusercontent.com`).

## Inputs

<!-- markdownlint-disable MD013 -->

| Name                        | Required | Default      | Description                                                                                                                           |
| --------------------------- | -------- | ------------ | ------------------------------------------------------------------------------------------------------------------------------------- |
| path_prefix                 | False    | `.`          | Directory containing the crate or workspace; must resolve within the workspace                                                        |
| manifest_path               | False    | `Cargo.toml` | Path to the crate's `Cargo.toml`, relative to `path_prefix`; with `workspace` or `packages`, any manifest of the workspace            |
| workspace                   | False    | `false`      | Publish every workspace member that the target registry accepts, in dependency order                                                  |
| packages                    | False    |              | Whitespace-separated workspace members to publish, in dependency order; replaces `workspace`                                          |
| exclude                     | False    |              | Whitespace-separated members to leave out; needs `workspace: true` and an empty `packages`                                            |
| release_tag                 | False    |              | Release tag that every selected crate's version must match, one leading `v` ignored                                                   |
| max_crate_size_bytes        | False    | `10485760`   | Largest allowed packaged `.crate` size in bytes; the default matches the crates.io 10MB cap                                           |
| dry_run                     | False    | `false`      | Check and package without publishing; needs no credentials                                                                            |
| registry                    | False    |              | Cargo registry name to publish to; empty or `crates-io` means crates.io. Needs `CARGO_REGISTRIES_<NAME>_INDEX`                        |
| registry_token              | False    |              | Registry token for the upload alone; empty falls back to the caller's Cargo credentials                                               |
| expected_sha256             | False    |              | `crate_sha256` from an earlier `dry_run` job, a JSON object for two or more crates; skips compilation and refuses a differing archive |
| permit_fail                 | False    | `false`      | Report success even when a stage fails                                                                                                |
| semver_checks               | False    | `false`      | Run `cargo-semver-checks` against the latest earlier crates.io release; crates.io dry runs alone                                      |
| cargo_semver_checks_version | False    | `0.51.0`     | `cargo-semver-checks` version to install for `semver_checks`                                                                          |
| summary                     | False    | `true`       | Write a crate table to the job summary                                                                                                |

<!-- markdownlint-enable MD013 -->

Boolean inputs accept the exact strings `true` and `false`; any other
value fails the run.

## Outputs

<!-- markdownlint-disable MD013 -->

| Name             | Description                                                                                                                 |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------- |
| crate_name       | Crate name, read from its `Cargo.toml`; two or more crates: names in publish order, space-separated                         |
| crate_version    | Crate version, read from its `Cargo.toml`; two or more crates: a JSON object of name to version                             |
| crate_size_bytes | Packaged `.crate` file size in bytes; two or more crates: a JSON object of name to size                                     |
| crate_sha256     | SHA-256 of the verified `.crate`, as the registry index records it; two or more crates: a JSON object of name to digest     |
| cargo_version    | Cargo version that packaged the crate                                                                                       |
| registry_status  | This version on the target registry: `absent`, `identical` (same archive) or `different`; two or more crates: a JSON object |
| publish_status   | Outcome: `published` (any crate uploaded), `skipped` (every archive already there), `dry-run` or `failed`                   |
| published        | `true` when this run uploaded a crate, even before a later failure; `false` for a skip too                                  |
| semver_status    | `semver_checks` outcome: `passed`, `failed` or `skipped`; empty when off or not reached; two or more crates: a JSON object  |
| semver_baseline  | crates.io version that `semver_checks` compared against; empty when none; two or more crates: a JSON object                 |

<!-- markdownlint-enable MD013 -->

## Implementation Details

The action runs these stages in order, and the first failure stops it:

1. **Check inputs**: checks booleans, the size limit and the
   release tag character set, and confirms that `path_prefix` and
   `manifest_path` resolve within `GITHUB_WORKSPACE`. A symlinked
   `Cargo.toml` fails, since it could point outside the workspace.
   A named `registry` needs a valid name and a sparse HTTPS index URL.
2. **Read registry config**: for a named `registry` alone, reads the
   index's `config.json` and requires an HTTPS `api` URL and no
   `auth-required`.
3. **Check toolchain**: asks rustup which toolchain the project
   selects, without running it, and pins that channel for every later
   stage. A path-based toolchain stops any release; see below.
4. **Read crate metadata**: `cargo metadata --no-deps` selects the
   package whose manifest matches `manifest_path`, which works for
   workspace members, or the members `workspace` or `packages` select;
   see [Workspaces](#workspaces).
5. **Verify release tag**: when `release_tag` holds a value, the
   crate version must equal it, after removing one leading `v`.
6. **Package**: `cargo package --locked` builds the `.crate` file and
   compiles it, proving the packaged sources build. With
   `expected_sha256`, it packages with `--no-verify` and compiles
   nothing.
7. **Check package size**: compares the `.crate` file against
   `max_crate_size_bytes`.
8. **Match verified digest**: with `expected_sha256`, the `.crate`
   must match it byte for byte.
9. **Check crates.io**, or the named registry: looks the version up
   in the registry's index and compares its recorded checksum with
   the `.crate`; see below.
10. **Check semver**: with `semver_checks`, runs the
    `cargo-semver-checks` executable directly (`check-release`), not
    through Cargo; see below.
11. **Dry-run publish**: `cargo publish --dry-run` runs the registry
    checks without uploading.
12. **Confirm package unchanged**: repackages without running crate
    code and requires a byte-identical `.crate`; see below.
13. **Publish**: unless `dry_run` is `true`, uploads the crate.

Packages go to a target directory the action creates, and it removes
that directory afterwards, so the checkout stays untouched.

### Workspaces

`workspace`, `packages` and `exclude` follow the other
`lfreleng-actions` Rust actions: a non-empty `packages` replaces
`workspace`, and `exclude` needs `workspace: true` with an empty
`packages`. Names must match `A-Z a-z 0-9 _ -`. One difference: here
`workspace` defaults to `false`, not `true`. v0.0.1 published the
package `manifest_path` names, even inside a workspace, and a default
of `true` would make those callers publish every member.

- **Selection.** `workspace: true` takes every workspace member less
  `exclude`, then leaves out each one whose `package.publish` excludes
  the target registry (`publish = false`, or a registry list without
  that registry's name), with a notice naming them. The list must
  spell the registry as `registry` does, or `crates-io` for
  crates.io: Cargo compares the names as plain strings, so `my_reg`
  does not match `my-reg`. `packages` must name members the target
  registry accepts; anything else fails. An `exclude` name that
  matches no member warns, as Cargo does.
- **Order.** The selection runs in dependency order: each crate
  follows the selected crates it depends on through normal, build or
  versioned dev dependencies, the ones a published manifest keeps.
  A dependency counts when its path is a member's directory. Cargo
  packages and uploads a member against the crates.io release of a
  dependency that names no path, even one `[patch]` points at a
  sibling, so that is no edge either. Crates go in rounds, as Cargo
  uploads them: each round holds, sorted by name, every crate whose
  dependencies came in earlier rounds. A cycle fails, as it does in
  Cargo.
- **One crate.** A selection of one runs as if
  `manifest_path` named that member, with the same outputs.
- **Two or more crates.** Each Cargo command receives the whole set as
  `-p` arguments, plus `--registry` for a named `registry`. Cargo then
  packages every member against the others' fresh archives, so a
  member whose sibling dependency is not on the registry yet still
  verifies, and the archives match the ones the upload builds.
  `cargo publish` uploads the set in dependency order, waiting for
  each crate to reach the index. The action does not use
  `cargo publish --workspace`, which fails outright when any member
  lists other registries but not the target, and cannot leave out
  members that are on the registry already. Every stage covers the
  whole set before the next begins, and each check applies per crate.
- **Digests.** With two or more crates, `crate_sha256` is a compact
  JSON object of crate name to digest, and `expected_sha256` takes
  that object back: it must be one JSON object, without repeated
  keys, naming the selected crates and no others, each with 64
  lowercase hexadecimal characters. A single digest for two or more
  crates fails. A one-entry object also works for a single crate.
- **Release tag.** One tag covers the set: every selected crate's
  version must equal `release_tag`. A GitHub release carries a single
  tag, so per-crate tags such as `<crate>-v<version>` would need a run
  per crate anyway; select each crate with `packages` for that.
- **Re-runs.** Members already on the target registry with identical
  archives skip, and the rest upload. If the upload fails part way,
  the action checks the registry's index for each remaining crate,
  reports the ones that arrived as published, sets `published` to
  `true` if any did, and fails; a re-run then resumes with the rest.
- **Summary.** One row per crate shows its outcome, size, registry
  state and digest, with a crates.io link once published there.
- **Named registries.** A set honours `registry` as one crate does:
  the same index checks, the token routed to
  `CARGO_REGISTRIES_<NAME>_TOKEN` for the upload alone, and the same
  requirements on the registry. A dependency on a sibling member must
  name that registry too (`registry = "<name>"` beside `path` and
  `version`): without it Cargo resolves the sibling from crates.io,
  and packaging fails while the sibling is not there.

### Toolchain and configuration

Cargo reads `.cargo/config.toml` from its working directory, and
rustup reads `rust-toolchain.toml` or `rust-toolchain` there too. Both
come from the repository, so both could steer a credentialed Cargo
run: a config file can route the upload through a proxy, and a
toolchain file can name an absolute path whose `cargo` binary rustup
then runs in place of the real one.

So the action runs the compiling **Package** stage alone in
the project directory, where the project's build configuration and
toolchain belong. Every other stage, the upload included, runs from
an empty directory, so no checked-in configuration reaches it.

The action pins the toolchain the project selects, provided rustup
manages it. `rustup show active-toolchain` names the selection
without running it:

<!-- markdownlint-disable MD013 -->

<!-- markdownlint-disable MD013 MD060 -->

| Project selects       | Plain dry run                           | Dry run with `release_tag`    | Upload                        |
| --------------------- | --------------------------------------- | ----------------------------- | ----------------------------- |
| A channel, or nothing | Pinned for every stage                  | Pinned for every stage        | Pinned for every stage        |
| A path                | ⚠️ Warns; runs in the project directory | ❌ Fails before running Cargo | ❌ Fails before running Cargo |

<!-- markdownlint-enable MD013 MD060 -->

<!-- markdownlint-enable MD013 -->

A dry run with a path toolchain holds no credentials, and no other
toolchain can reproduce its archives, so it keeps running there.
Nothing the repository supplies ever runs as the uploading `cargo`.

### Already published versions

crates.io never lets anyone replace a version, even once yanked, and
Cargo refuses to publish a version any registry already holds. Before
the dry run, the action looks the version up in the target registry's
sparse index, whose recorded checksum is the SHA-256 of the published
`.crate`, and compares it with `crate_sha256`. A named registry may
answer 404, 410 or 451 for a crate it lacks, as Cargo's sparse
protocol allows; crates.io must answer 404:

<!-- markdownlint-disable MD013 -->

<!-- markdownlint-disable MD013 MD060 -->

| In the registry   | Plain dry run             | Dry run with `release_tag` | Upload                             |
| ----------------- | ------------------------- | -------------------------- | ---------------------------------- |
| Absent            | ✅ Pass                   | ✅ Pass                    | Upload                             |
| Identical archive | ✅ Pass                   | ✅ Pass                    | ⛔️ Skip, `publish_status: skipped` |
| Different content | ⚠️ Warn: bump the version | ❌ Fail                    | ❌ Fail before the upload          |

<!-- markdownlint-enable MD013 MD060 -->

<!-- markdownlint-enable MD013 -->

A dry run with `release_tag` is the verification job of a release, so
it fails for anything that would stop the release. A pull request's
dry run between releases routinely finds different content under an
unbumped version, which merits a warning but not a failure. Skipping
an identical archive makes a re-run safe, such as one that retries
the remaining crates of a workspace release after a partial failure.
If an upload fails but the index then shows this exact archive, as
after a timeout, the action reports it as skipped rather than failed.

### Credential handling

Packaging compiles the crate, which runs its build scripts and
procedural macros, and those of its dependencies. Code in a job can
reach that job's credentials: on Linux, a same-user process can read
an ancestor's original environment through `/proc/<pid>/environ`,
whatever later steps unset. That includes `registry_token` and, with
`id-token: write`, the variables that mint a Trusted Publishing
token.

Isolation instead comes from separate jobs, as in the
[usage example](#usage-example):

- The `verify` job runs with `dry_run: 'true'` and no credentials or
  `id-token` permission. It compiles the crate and reports the
  archive's `crate_sha256`.
- The `publish` job passes that digest as `expected_sha256`. The
  action then packages with `--no-verify`, runs no crate code, and
  refuses to upload unless the archive matches byte for byte.
  Cargo's archives are reproducible across checkouts, so the same
  commit and Cargo version yield the same digest.

In a single job the action still limits exposure, as defence in
depth rather than isolation:

- `registry_token` goes to the final upload alone; the action unsets
  it before running Cargo and masks it in the log.
- It runs every Cargo stage before the upload, and `rustup`, without
  `CARGO_REGISTRY_TOKEN`, any `CARGO_REGISTRIES_<NAME>_TOKEN`, the
  GitHub OIDC request variables (`ACTIONS_ID_TOKEN_REQUEST_*`),
  `ACTIONS_RUNTIME_TOKEN`, or the runner's command files
  (`GITHUB_OUTPUT`, `GITHUB_ENV`, `GITHUB_PATH`, `GITHUB_STATE`,
  `GITHUB_STEP_SUMMARY`). Crate code could otherwise use those files to
  forge step outputs, environment variables, `PATH` entries or the job
  summary. Their paths are predictable, so this hinders rather than
  prevents it. Other registry settings, such as
  `CARGO_REGISTRIES_<NAME>_INDEX`, stay.
- The upload gets the same scrub, except that it keeps the token
  variables of the registry it targets.
- The upload passes `--no-verify`, so it compiles nothing.

With `registry_token` set, the upload also forces Cargo's built-in
`cargo:token` credential provider. With `registry_token` empty, the
upload uses whatever credentials and provider the caller configured.
For a named registry, the token reaches the upload as
`CARGO_REGISTRIES_<NAME>_TOKEN`, and the upload gets no crates.io
token variable.

### Package integrity

Cargo cannot upload a prebuilt archive: `cargo publish` always
packages afresh. Build scripts that ran during verification could
edit and commit the workspace sources, but Cargo's own check covers
the unpacked copy under `target/package`, not the workspace. The
upload would then ship sources that nobody compiled.

The **Confirm package unchanged** stage closes that gap. It
repackages with `--no-verify`, which runs no crate code, and fails
unless the result matches the verified archive's SHA-256 byte for
byte. Cargo's archives are reproducible and record the source
commit, so any change to the packaged inputs alters the digest. The
`crate_sha256` output reports that digest, which crates.io records
as the published crate's checksum.

A process started by a build script can outlive it, though, and the
action cannot rule out changes between that stage and the upload in
a single job. The two-job pattern avoids the question: no crate code
ever runs in the publishing job.

The action cannot hide files such as `$CARGO_HOME/credentials.toml`
from code in the same job, so prefer `registry_token` with a
short-lived Trusted Publishing token.

### Semver checks

crates.io versions are permanent, and Cargo upgrades dependents to any
newer minor or patch release. A breaking change published as a patch
breaks the next build of every dependent. With `semver_checks` set to
`true`, the action runs
[cargo-semver-checks](https://github.com/obi1kenobi/cargo-semver-checks)
to catch that before release.

**Unprivileged dry runs alone.** The check compiles the crate and
the published baseline, running their build scripts and procedural
macros. It fails the run, whatever `permit_fail` says, when the run
could publish or holds a publishing credential:

- `dry_run` is `false`;
- `expected_sha256` holds a value: the publishing job of the two-job
  pattern, which compiles nothing;
- `registry_token` holds a value;
- `CARGO_REGISTRY_TOKEN` or any `CARGO_REGISTRIES_<NAME>_TOKEN` holds a
  value in the environment;
- `ACTIONS_ID_TOKEN_REQUEST_TOKEN` or `ACTIONS_ID_TOKEN_REQUEST_URL`
  holds a value, meaning the job has `id-token: write`;
- `$CARGO_HOME/credentials.toml` or `$CARGO_HOME/credentials` exists.
  The action resolves a relative `CARGO_HOME` from `path_prefix`, as
  the **Package** stage's Cargo does; see **Cargo home** below.

An empty variable carries no credential and does not count. Run the
check in the `verify` job, as shown in
[Check semver compatibility before release](#check-semver-compatibility-before-release).

**crates.io alone.** `cargo-semver-checks` takes its baseline from
crates.io and supports no other registry. A crate bound for a named
`registry` may have no release on crates.io, or crates.io may hold an
unrelated crate under the same name, and the comparison would mean
nothing. The action fails the run, whatever `permit_fail` says, when
`semver_checks` meets a named `registry`, rather than skipping with a
notice: a skip would leave a passing job that checked nothing.
`registry: crates-io` names crates.io and works.

**Workspace sets.** When `workspace` or `packages` selects two or more
crates, the check runs for each crate of the set in publish order,
from that crate's own manifest, against that crate's latest earlier
release on crates.io, by the baseline rules below. A crate's first
release skips with a notice, as does a crate whose exact archive
crates.io already holds, and the rest of the set still runs the
check. Each crate compiles from the workspace as it stands, with its
sibling dependencies as path dependencies, so the comparison is the
one `cargo-semver-checks` makes for that crate alone. The check runs
after **Check crates.io** and before **Dry-run publish** and
**Confirm package unchanged**, as for one crate. A crate with
breaking changes does not stop the others, so one run reports every
finding; the run then fails with the first failure's exit status. An
index or tool error fails at once. `semver_status` and
`semver_baseline` become JSON objects keyed by crate name, as the
set's other outputs do, and the **Semver** row lists each crate. A
selection of one crate runs the check as `manifest_path` would.

**Baseline.** The check compares against the highest version on
crates.io that is neither yanked nor a pre-release, and not above the
crate's own version. A pre-release compares against an earlier
release. When crates.io holds this version with different bytes, as in
a plain dry run of a published version, the check compares against
that published version. It skips, with a notice, when:

- crates.io holds no such version, as for a first release;
- crates.io already holds this exact archive, so nothing new would
  ship.

An index lookup that fails, or that answers with anything other than
index entries, fails the run instead of skipping: a malformed or empty
response never counts as a first release.

**Placement.** The check runs after **Check crates.io**, because the
skip for an identical archive needs the packaged digest and the
registry state. It runs before **Confirm package unchanged**, so that
stage also catches any source edits made by code the check compiled.

**Findings** appear in the step log, as `cargo-semver-checks` prints
them, and in a **Semver** row of the job summary that names the failed
lints. They fail the run, and the step exits with the tool's status,
100 for failed lints. With `permit_fail: true` the step reports
success instead, and `semver_status` stays `failed`.

**Environment.** The check runs from a fresh empty directory, with an
absolute `--manifest-path`, pinned to the same toolchain as every
stage, and builds under the action's temporary directory.
`cargo-semver-checks` resolves crates.io through any source
replacement in the Cargo configuration of its working directory, so
from the project directory a checked-in `.cargo/config.toml` could
swap in a forged baseline and fake a pass. As a consequence, the
project's `.cargo/config.toml` does not apply to the check's builds;
it still applies to **Package**. rustup finds a path-based toolchain
from the project directory alone, so such a toolchain keeps the check
there; the action already warns about it. The action runs the
`cargo-semver-checks` executable itself, not `cargo semver-checks`: a
Cargo alias in the checkout could shadow that subcommand and fake a
pass. The tool and everything it starts get the environment scrub
that every Cargo stage gets, from the same helper; see
[Credential handling](#credential-handling). They never see
`CARGO_REGISTRY_TOKEN`, any `CARGO_REGISTRIES_<NAME>_TOKEN`,
`ACTIONS_ID_TOKEN_REQUEST_TOKEN`, `ACTIONS_ID_TOKEN_REQUEST_URL`,
`ACTIONS_RUNTIME_TOKEN`, or the runner command files `GITHUB_OUTPUT`,
`GITHUB_ENV`, `GITHUB_PATH`, `GITHUB_STATE` and `GITHUB_STEP_SUMMARY`.
Withholding the command files stops crate code from casually forging
step outputs, environment variables, `PATH` entries or the job
summary. That is defence in depth, not a boundary: their paths are
predictable, and same-user code can still find them.

**Cargo home.** Cargo also reads source replacement from
`$CARGO_HOME/config.toml`, so a Cargo home inside the checkout would let
checkout files swap in a forged baseline. With `semver_checks` set to
`true`, the action fails the run, whatever `permit_fail` says, when
`CARGO_HOME` resolves inside `GITHUB_WORKSPACE`. It resolves a relative
value from `path_prefix`, as the **Package** stage's Cargo does, and
follows symlinks through every directory of that path that exists. The
check then gets that resolved, absolute path. An unset `CARGO_HOME`,
meaning `~/.cargo`, is fine.

**Limits.** The check catches accidental breaking changes, but offers
no boundary against a hostile checkout: the build scripts and procedural
macros it compiles run as the job's user, and the crate's own
`cargo-semver-checks` lint settings in `Cargo.toml` can relax lints.
Review changes to those as you would any release-relevant code.

Cargo still honours source replacement in a Cargo home outside the
checkout, and in `.cargo/config.toml` in any parent directory of the
check's working directory outside the checkout, such as
`/home/runner/.cargo/config.toml` on GitHub-hosted runners. Writing
those takes code that already ran as the job's user earlier in the same
job, such as an earlier step, or the build scripts that **Package**
compiles before the check. As with the environment scrub, the action
draws its boundary at the job: run the check in a job that compiles
nothing else beforehand, and whose setup does not replace crates.io.

**Tool and toolchain.** The action installs `cargo-semver-checks`
through `taiki-e/install-action` as a prebuilt, checksum-verified
release, with no fallback to other download methods.
`cargo_semver_checks_version` must name a version that the pinned
install-action release lists. `cargo-semver-checks` reads rustdoc JSON, an unstable
format, so each release supports a range of Rust versions: 0.51.0
needs Rust 1.93 or newer. A project that pins an older toolchain
needs an older `cargo_semver_checks_version`.

### Failure handling

Errors name the input or stage at fault and keep Cargo's exit code.
With `permit_fail` set to `true`, a failed stage produces a warning
and the step reports success; `published` then reads `false`. Invalid
inputs always fail the run, whatever `permit_fail` says.

Before a real upload the action prints a notice naming the repository
and workflow file, the fields a crates.io Trusted Publisher
configuration binds a token to.

### Job summary

Each call appends a section to the job summary: a headline with the
outcome, the reason for any failure, a table of checks, and a list of
warnings, Cargo's own included. For example:

<!-- markdownlint-disable MD013 MD033 -->

```markdown
## 🦀 Rust Crate Publish

### ✅ Dry run passed: lfreleng-test-rust-project 0.1.0

<!-- markdownlint-disable MD013 MD060 -->

| Check        | Result                                                                        |
| ------------ | ----------------------------------------------------------------------------- |
| Mode         | Dry run: nothing uploaded                                                     |
| Manifest     | <code>test-rust-project/Cargo.toml</code>                                     |
| Toolchain    | <code>cargo 1.98.1</code> via <code>stable-x86_64-unknown-linux-gnu</code>    |
| Release tag  | ✅ <code>v0.1.0</code> matches                                                |
| Verification | ✅ Compiled and verified in this job                                          |
| Package size | ✅ 6.8 KiB of the 10.0 MiB limit                                              |
| crates.io    | ✅ Version not yet published                                                  |
| SHA-256      | <code>3c8bdba0cee1a8887ae312331ca76aff760f3d4e82787aefd71ae848aee6176e</code> |

<!-- markdownlint-enable MD013 MD060 -->
```

<!-- markdownlint-enable MD013 MD033 -->

Headlines distinguish 🚀 published, ⛔️ skipped as already
published, ✅ dry run passed, and ❌ failed at a named stage, with
⚠️ marking a failure that `permit_fail` let through. Checks the run
never reached read "Not reached". A crate published to or skipped on
crates.io links to its crates.io page; for a named registry, the
summary names the registry and gives no link. With `semver_checks`, a
**Semver** row reports the check. The summary never includes
credentials.

## Testing

`.github/workflows/testing.yaml` runs on every pull request:

- Unit tests: [Bats](https://github.com/bats-core/bats-core) suites
  in `tests/` drive `scripts/publish-crate.sh` against stand-ins for
  Cargo, rustup and the registry index, covering each stage, input
  validation, credential handling, named registries and the summary.
- Dry runs against a generated two-member workspace and against
  [test-rust-project](https://github.com/lfreleng-actions/test-rust-project),
  the latter also through a named registry whose index is crates.io's
  own. CI never publishes, so no test reaches a registry's upload
  API.
- Failure cases, which must fail closed.
- Release safeguards against real rustup and the live crates.io
  index: a path-based toolchain, and a version already published
  with different content.

Run the unit tests locally with Bats 1.7.0 or later:

```bash
bats tests/
```

## Acknowledgements

This action began as the `publish-crate-to-crates-io` composite action
that [John McCall](https://github.com/lowlydba) wrote for Overture Maps,
and contributed to `OvertureMaps/workflows` in
[pull request #105](https://github.com/OvertureMaps/workflows/pull/105).
The Linux Foundation imported it at commit
[`2ba5afb`](https://github.com/OvertureMaps/workflows/tree/2ba5afb48f6cff2989cc52e6cf93fef509cc3e76/.github/actions/publish-crate-to-crates-io)
without its history, which lives in that monorepo.

The original design shapes this action still: its inputs and
outputs, the staged checks that each report their failing stage, the
`cargo metadata` lookup that selects a workspace member by manifest
path, the release tag comparison, the size limit, the job summary
table, the Trusted Publishing notice, and the Bats suite with its
mocked Cargo. Our thanks to John for that work.

The [`NOTICE`](NOTICE) file records this origin alongside the copyright
notice.

## Licensing

This action derives from the `publish-crate-to-crates-io` action
described in [Acknowledgements](#acknowledgements), copyright 2026
Overture Maps and released under the MIT License. It remains under
that licence alone:

- `action.yaml`, `scripts/`, the tests and fixtures derived from the
  original, and this README name MIT as their licence in their SPDX
  headers. Each keeps the Overture Maps copyright notice, and The
  Linux Foundation releases its modifications under the same MIT
  terms.
- `LICENSE` and `LICENSES/MIT.txt` reproduce the upstream licence
  verbatim, copyright notice included, and `NOTICE` records where
  the original came from and who wrote it.
- Files that did not come from the original, such as the repository
  scaffolding from the `lfreleng-actions` template, name Apache-2.0
  in their SPDX headers, with the text in `LICENSES/Apache-2.0.txt`.

Each file's SPDX header states which licence applies to it.

[pre-commit.ci results page]: https://results.pre-commit.ci/latest/github/lfreleng-actions/rust-crate-publish-action/main
[pre-commit.ci status badge]: https://results.pre-commit.ci/badge/github/lfreleng-actions/rust-crate-publish-action/main.svg
