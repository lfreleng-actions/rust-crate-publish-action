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
crates.io.

## rust-crate-publish-action

The action publishes one crate per call. It targets crates.io and
suits
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

### Publish workspace members in dependency order

Call the action once per crate, dependencies first, and select each
member with `manifest_path`. Crates.io must list a Trusted Publisher
for each crate.

This example runs in a single job, because Cargo cannot package a
dependent crate until the dependency version it needs is on
crates.io. So it lacks the two-job isolation described in
[Credential handling](#credential-handling). A crate whose
dependencies are all published already can use the two-job pattern
instead:

<!-- markdownlint-disable MD013 MD046 -->

```yaml
- name: "Authenticate for the base crate"
  id: auth-base
  uses: rust-lang/crates-io-auth-action@c6f97d42243bad5fab37ca0427f495c86d5b1a18 # v1.0.5

- name: "Publish the base crate"
  uses: lfreleng-actions/rust-crate-publish-action@main
  with:
    manifest_path: crates/base/Cargo.toml
    release_tag: ${{ github.event.release.tag_name }}
    registry_token: ${{ steps.auth-base.outputs.token }}

- name: "Authenticate for the dependent crate"
  id: auth-app
  uses: rust-lang/crates-io-auth-action@c6f97d42243bad5fab37ca0427f495c86d5b1a18 # v1.0.5

- name: "Publish the dependent crate"
  uses: lfreleng-actions/rust-crate-publish-action@main
  with:
    manifest_path: crates/app/Cargo.toml
    release_tag: ${{ github.event.release.tag_name }}
    registry_token: ${{ steps.auth-app.outputs.token }}
```

<!-- markdownlint-enable MD013 MD046 -->

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
- Network access to `index.crates.io` for the version check and the
  dry run, plus `static.crates.io` to download dependencies and
  `crates.io` to publish. Block-mode egress policies must admit these
  hosts; the `lfreleng-actions` allow-list does from v0.16.3.

## Inputs

<!-- markdownlint-disable MD013 -->

| Name                 | Required | Default      | Description                                                                                     |
| -------------------- | -------- | ------------ | ----------------------------------------------------------------------------------------------- |
| path_prefix          | False    | `.`          | Directory containing the crate or workspace; must resolve within the workspace                  |
| manifest_path        | False    | `Cargo.toml` | Path to the crate's `Cargo.toml`, relative to `path_prefix`                                     |
| release_tag          | False    |              | Release tag that the `Cargo.toml` version must match, one leading `v` ignored                   |
| max_crate_size_bytes | False    | `10485760`   | Largest allowed packaged `.crate` size in bytes; the default matches the crates.io 10MB cap     |
| dry_run              | False    | `false`      | Check and package without publishing; needs no credentials                                      |
| registry_token       | False    |              | crates.io token for the upload alone; empty falls back to the caller's Cargo credentials        |
| expected_sha256      | False    |              | `crate_sha256` from an earlier `dry_run` job; skips compilation and refuses a differing archive |
| permit_fail          | False    | `false`      | Report success even when a stage fails                                                          |
| summary              | False    | `true`       | Write a crate table to the job summary                                                          |

<!-- markdownlint-enable MD013 -->

Boolean inputs accept the exact strings `true` and `false`; any other
value fails the run.

## Outputs

<!-- markdownlint-disable MD013 -->

| Name             | Description                                                                              |
| ---------------- | ---------------------------------------------------------------------------------------- |
| crate_name       | Crate name, read from its `Cargo.toml`                                                   |
| crate_version    | Crate version, read from its `Cargo.toml`                                                |
| crate_size_bytes | Packaged `.crate` file size in bytes                                                     |
| crate_sha256     | SHA-256 of the verified `.crate`, as crates.io records it                                |
| cargo_version    | Cargo version that packaged the crate                                                    |
| registry_status  | This version on crates.io: `absent`, `identical` (same archive) or `different`           |
| publish_status   | Outcome: `published`, `skipped` (identical archive already there), `dry-run` or `failed` |
| published        | `true` when this run uploaded the crate; `false` for a skip too, see `publish_status`    |

<!-- markdownlint-enable MD013 -->

## Implementation Details

The action runs these stages in order, and the first failure stops it:

1. **Check inputs**: checks booleans, the size limit and the
   release tag character set, and confirms that `path_prefix` and
   `manifest_path` resolve within `GITHUB_WORKSPACE`. A symlinked
   `Cargo.toml` fails, since it could point outside the workspace.
2. **Check toolchain**: asks rustup which toolchain the project
   selects, without running it, and pins that channel for every later
   stage. A path-based toolchain stops any release; see below.
3. **Read crate metadata**: `cargo metadata --no-deps` selects the
   package whose manifest matches `manifest_path`, which works for
   workspace members.
4. **Verify release tag**: when `release_tag` holds a value, the
   crate version must equal it, after removing one leading `v`.
5. **Package**: `cargo package --locked` builds the `.crate` file and
   compiles it, proving the packaged sources build. With
   `expected_sha256`, it packages with `--no-verify` and compiles
   nothing.
6. **Check package size**: compares the `.crate` file against
   `max_crate_size_bytes`.
7. **Match verified digest**: with `expected_sha256`, the `.crate`
   must match it byte for byte.
8. **Check crates.io**: looks the version up in the crates.io index
   and compares its recorded checksum with the `.crate`; see below.
9. **Dry-run publish**: `cargo publish --dry-run` runs the registry
   checks without uploading.
10. **Confirm package unchanged**: repackages without running crate
    code and requires a byte-identical `.crate`; see below.
11. **Publish**: unless `dry_run` is `true`, uploads the crate.

Packages go to a target directory the action creates, and it removes
that directory afterwards, so the checkout stays untouched.

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

crates.io never lets anyone replace a version, even once yanked. Before
the dry run, the action looks the version up in the crates.io index,
whose recorded checksum is the SHA-256 of the published `.crate`, and
compares it with `crate_sha256`:

<!-- markdownlint-disable MD013 -->

<!-- markdownlint-disable MD013 MD060 -->

| On crates.io      | Plain dry run             | Dry run with `release_tag` | Upload                             |
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
- It strips `CARGO_REGISTRY_TOKEN`, `CARGO_REGISTRIES_CRATES_IO_TOKEN`
  and the GitHub OIDC request variables (`ACTIONS_ID_TOKEN_REQUEST_*`)
  from every Cargo stage before the upload.
- The upload passes `--no-verify`, so it compiles nothing.

With `registry_token` set, the upload also forces Cargo's built-in
`cargo:token` credential provider. With `registry_token` empty, the
upload uses whatever credentials and provider the caller configured.

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
never reached read "Not reached". A published or skipped crate links
to its crates.io page. The summary never includes credentials.

## Testing

`.github/workflows/testing.yaml` runs on every pull request:

- Unit tests: [Bats](https://github.com/bats-core/bats-core) suites
  in `tests/` drive `scripts/publish-crate.sh` against stand-ins for
  Cargo, rustup and the crates.io index, covering each stage, input
  validation, credential handling and the summary.
- Dry runs against a generated two-member workspace and against
  [test-rust-project](https://github.com/lfreleng-actions/test-rust-project).
- Failure cases, which must fail closed.
- Release safeguards against real rustup and the live crates.io
  index: a path-based toolchain, and a version already published
  with different content.

Run the unit tests locally with Bats 1.7.0 or later:

```bash
bats tests/
```

## Licensing

This action derives from the `publish-crate-to-crates-io` action in
[OvertureMaps/workflows](https://github.com/OvertureMaps/workflows/tree/2ba5afb48f6cff2989cc52e6cf93fef509cc3e76/.github/actions/publish-crate-to-crates-io),
copyright 2026 Overture Maps and released under the MIT License. It
remains under that licence alone:

- `action.yaml`, `scripts/`, the tests and fixtures derived from the
  original, and this README name MIT as their licence in their SPDX
  headers. Each keeps the Overture Maps copyright notice, and The
  Linux Foundation releases its modifications under the same MIT
  terms.
- `LICENSE` and `LICENSES/MIT.txt` reproduce the upstream licence
  verbatim, copyright notice included.
- Files that did not come from the original, such as the repository
  scaffolding from the `lfreleng-actions` template, name Apache-2.0
  in their SPDX headers, with the text in `LICENSES/Apache-2.0.txt`.

Each file's SPDX header states which licence applies to it.

[pre-commit.ci results page]: https://results.pre-commit.ci/latest/github/lfreleng-actions/rust-crate-publish-action/main
[pre-commit.ci status badge]: https://results.pre-commit.ci/badge/github/lfreleng-actions/rust-crate-publish-action/main.svg
