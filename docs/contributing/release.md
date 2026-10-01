# Release

How to cut a release of the Purse Headless Checkout iOS SDK. Replayable by any team member:
nothing below depends on a person's machine.

## Overview

The release is driven from GitHub, exactly like
[purse-securefields-ios](https://github.com/UpStreamPay/purse-securefields-ios):

| Step | Trigger | What happens |
|---|---|---|
| 1 | Push to `main` | `release-please.yml`: conventional commits decide the next version; a **release PR** carries the version and the changelog |
| 2 | Release PR merged | release-please creates tag `v<version>` and publishes the GitHub release with the changelog |
| 3 | Release published, after a codeowner approves | `release.yml`: builds and signs the XCFrameworks, rewrites `Package.swift` to binary targets, moves the tag onto that commit and attaches the zips |

Merging the release PR is all it takes to start a release; a codeowner then approves it before
anything is built or signed. Pushes made only of non-releasable commits (`docs:`, `chore:`, …)
produce no release PR.

## What gets published

One tag, resolved by SPM at `https://github.com/UpStreamPay/purse-headless-checkout-ios.git`. At
that tag `Package.swift` points at three signed XCFrameworks attached to the GitHub release —
`PurseHeadlessCheckout`, `PurseCheckoutApplePay`, `PurseCheckoutKlarna` — while
`PurseCheckoutPayPal` stays a source target (see `scripts/binary-manifest.py`). Before anything is
uploaded, the workflow checks every slice has a `.swiftinterface`, every plugin links the core
framework instead of embedding it, the privacy manifest is at the framework root, and the published
layout compiles for a consumer.

## Prerequisites (one-time setup)

**Secrets.** None is organisation-wide.

| Secret | Where | Value |
|---|---|---|
| `RELEASE_PLEASE_TOKEN` | `release-please` **and** `release` environments (the same value in both; never a repository secret) | Fine-grained PAT on this repository alone with **Contents**, **Pull requests** and **Issues: Read and Write**, so CI runs on the release PR and the published release triggers `release.yml` (events raised by `GITHUB_TOKEN` start no workflow). Its account must be a repository admin: the `v*` tag ruleset lets only admins create or move a tag, and both release-please and `release.yml`'s retag write one. It expires — put the rotation in a calendar, and update both copies. |
| `APPLE_SIGNING_CERT_P12_BASE64` | `release` environment | The Apple Distribution certificate **and its private key**, exported as `.p12`, base64-encoded — the same one as Secure Fields |
| `APPLE_SIGNING_CERT_P12_PASSWORD` | `release` environment | The `.p12` export password |

`release.yml` checks its three secrets inside the gated job and **fails** with their names when one
is missing. Without that check, the v1.1.0 run died inside the certificate import and
1.1.0 shipped with no XCFrameworks.

`GITHUB_TOKEN` covers the asset upload, under the job's `contents: write`. The tag move does not use
it: `GITHUB_TOKEN` cannot bypass the `release tags` ruleset (see
[ci.md](ci.md#repository-settings)). `RELEASE_PLEASE_TOKEN` is used for that one `git push` only and
never given to checkout, so it is not in `.git/config` while third-party package code builds.

## Release approval

`release.yml` runs in the **`release` environment**. Each run waits until a member of
`@UpStreamPay/pci-dss` approves it under **Actions → the run → Review deployments**; GitHub emails
the reviewers. The person who started the run cannot approve it, and only `v*` tags may deploy to
the environment (PCI-DSS 6.5.1).

Two more guards keep unreviewed or untrusted output out of a release:

- **The workflow refuses a tag that is not on `main`.** Only code that went through a reviewed PR
  is built and signed.
- **It signs only with a valid identity.** An expired or untrusted one would still sign, and ship
  a signature no consumer can trust.

Around them, repository settings (applied once by an admin, see [ci.md](ci.md#repository-settings)):
the `main` ruleset and the `v*` tag ruleset.

### Why two environments, `release-please` and `release`

Both jobs that need `RELEASE_PLEASE_TOKEN` must run under different rules, and an environment holds
only one set of rules (one reviewer list, one list of refs allowed to deploy):

| | `release-please` | `release` |
|---|---|---|
| Job | `release-please.yml` | `release.yml` |
| Runs | on every push to `main`, unattended | on a published release (`v*` tag) |
| Approval | none: it only opens or updates the release PR, which is reviewed anyway | `@UpStreamPay/pci-dss`: it signs and publishes binaries |
| Deploys from | `main` | `v*` tags |
| Secrets | `RELEASE_PLEASE_TOKEN` | `RELEASE_PLEASE_TOKEN`, `APPLE_SIGNING_*` |

Every way of collapsing them into one gives one of the jobs the wrong rules:

- **One environment with reviewers** (`main` and `v*`): every merge to `main` waits for a pci-dss
  approval before release-please can run. An approval per merge, for a job that publishes nothing,
  trains reviewers to click through the one approval that matters.
- **One environment without reviewers**: the release loses its approval gate (PCI-DSS 6.5.1).
- **No environment for release-please, token as a repository secret**: a workflow pushed on any
  branch can read a repository secret, and this one is an admin's token that bypasses the `release
  tags` ruleset.

A job also runs in exactly one environment, so `release.yml` cannot borrow the token from
`release-please` — and it runs from a tag, which that environment's `main`-only policy rejects.

The cost is **two copies of the same token**: rotate them together. A GitHub App (short-lived
installation tokens, nothing to rotate) would remove the rotation but not the two environments; it
needs an org admin to create.

## Versioning

release-please owns the version in three places at once: the git tag,
`.release-please-manifest.json` and the `x-release-please-version` annotation in
`Sources/PurseHeadlessCheckout/Core/SDKVersion.swift`. `SDKVersion.value` is the `version` field
on every monitoring event, so the tagged commit must report its own version.

| Commit prefix | Bump |
|---|---|
| `feat!:` / `BREAKING CHANGE:` footer | major: `1.2.3` → `2.0.0` |
| `feat:` | minor: `1.2.3` → `1.3.0` |
| `fix:`, `perf:` | patch: `1.2.3` → `1.2.4` |
| `docs:`, `chore:`, `style:`, `test:`, `ci:`, `build:`, `refactor:` | none |

## Local verification

```sh
./scripts/build-xcframeworks.sh   # unsigned XCFrameworks into xcframeworks/; Package.swift is restored on exit
```

## See also

- [CI and quality gates](ci.md) — what blocks a merge, and the repository settings
