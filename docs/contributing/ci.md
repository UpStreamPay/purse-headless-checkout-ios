# CI and quality gates

`.github/workflows/ci.yml` runs on every pull request and every push to `main`. The `main` ruleset
requires its two jobs (and `Dependency review`, see [Dependencies](#dependencies)), so a merge is
blocked on any of:

| Job | Gate | Fails when |
|---|---|---|
| Library Tests | tests | `xcodebuild test -scheme PurseHeadlessCheckout` fails on the newest iPhone simulator |
| Demo App | consumer build | `Demo/Demo.xcodeproj` fails to build in **Debug** or **Release** |

Both run the same way locally — the commands are in [AGENTS.md](../../AGENTS.md#build--verify).
The simulator is picked by `.github/actions/ios-simulator`, which also waits for it to finish
booting so a slow boot is not reported as a test failure.

## Dependencies

`.github/workflows/dependencies.yml` runs `Dependency review` on every pull request: it fails when
the change adds or moves a dependency to a version with a known **high** or **critical**
vulnerability. GitHub reads `Package.resolved` directly, so — unlike Android — there is no graph to
submit first. Dependabot alerts come from the same graph.

Dependabot (`.github/dependabot.yml`) proposes weekly updates of the Swift packages and of the
pinned GitHub Actions.

`.github/workflows/codeql.yml` scans **Swift** and the **workflows** (`actions`) on every pull
request, every push to `main` and weekly. It is an advanced setup on purpose: GitHub's default setup
builds Swift with `swift build`, which fails for an iOS-only package, so the Swift job builds each
product's own scheme for the simulator instead. Code scanning must be enabled on the repository with
**default setup off** — GitHub rejects advanced-setup results while default setup is on. The `main`
ruleset blocks a merge on a high or critical code scanning alert.

## Workflow hygiene

- Every action is pinned by commit SHA with its version in a trailing comment; Dependabot's
  `github-actions` updates rewrite both, under a `ci:` prefix that keeps them out of the changelog.
- Every workflow declares `permissions:`, read-only unless a job needs more, and every job has a
  `timeout-minutes`.
- Untrusted text (a tag name, a branch name) reaches a script only through `env`, never through
  `${{ }}` interpolation into the script itself.
- No organisation-wide token: release-please uses a fine-grained token scoped to this repository
  (see [release.md](release.md#prerequisites-one-time-setup)).

## Repository settings

Repository settings, not code — a repository admin applies them once. `.github/CODEOWNERS` makes
`@UpStreamPay/pci-dss` the owner of every file; the team needs **write** access to the repository
for that to apply.

**`main` ruleset** (Settings → Rules → Rulesets):

- no deletion, no force-push, no bypass
- pull request required, **1 approval**, **review from a code owner**, approvals dismissed on a new push
- status checks, **strict** (branch up to date with `main`): `Library Tests`, `Demo App`,
  `Dependency review`, `CodeQL (swift)`, `CodeQL (actions)`
- code scanning: CodeQL, blocking on high or critical security alerts and on errors

**`release tags` ruleset** on `refs/tags/v*`: creation, update and deletion restricted. Bypass:
repository admins (release-please's token belongs to one, so it can create the tag) **and the
GitHub Actions app** — `release.yml` force-moves the tag onto the binary-manifest commit with
`GITHUB_TOKEN`, and without the bypass every release fails at *Commit & retag*.

**`release` environment**: required reviewers `@UpStreamPay/pci-dss`, self-review prevented,
deployments only from `v*` tags. It holds the `APPLE_SIGNING_*` secrets. It must exist **before**
a workflow naming it runs, otherwise GitHub creates it with no protection.

**Code security**: code scanning (CodeQL, default setup off — see [Dependencies](#dependencies)),
secret scanning and push protection on. On a private repository these need GitHub Advanced
Security.

**Actions** (Settings → Actions → General): the default `GITHUB_TOKEN` is read-only and workflows
cannot approve pull requests.
