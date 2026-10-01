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
| `RELEASE_PLEASE_TOKEN` | repository | Fine-grained PAT on this repository alone with **Contents**, **Pull requests** and **Issues: Read and Write**, so CI runs on the release PR and the published release triggers `release.yml` (events raised by `GITHUB_TOKEN` start no workflow). Its account must be a repository admin: the `v*` tag ruleset lets only admins create tags. It expires — put the rotation in a calendar. |
| `APPLE_SIGNING_CERT_P12_BASE64` | `release` environment | The Apple Distribution certificate **and its private key**, exported as `.p12`, base64-encoded — the same one as Secure Fields |
| `APPLE_SIGNING_CERT_P12_PASSWORD` | `release` environment | The `.p12` export password |

`release.yml` checks the two signing secrets inside the gated job and **fails** with their names
when one is missing. Without that check, the v1.1.0 run died inside the certificate import and
1.1.0 shipped with no XCFrameworks.

`GITHUB_TOKEN` covers the rest: the tag move and the asset upload, under the job's
`contents: write`.

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
