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

## Pull request titles

Merges into `main` are squash-only, so a pull request's **title** becomes the commit on `main`, and
release-please reads it to decide the next version and the changelog section. `PR title`
(`.github/workflows/pr-title.yml`, a required check) fails unless the title is a Conventional Commit:
`<type>(<optional scope>)<optional !>: <description>`, with type one of `feat`, `fix`, `perf`,
`revert`, `docs`, `refactor`, `test`, `ci`, `build`, `chore` or `style`. It reruns when the title is
edited. A title that would fail here — `Feat/monitoring`, a branch name — releases nothing.

## Dependencies

`.github/workflows/dependencies.yml` runs `Dependency review` on every pull request: it fails when
the change adds or moves a dependency to a version with a known **high** or **critical**
vulnerability. GitHub reads `Package.resolved` directly, so — unlike Android — there is no graph to
submit first. Dependabot alerts come from the same graph.

Dependabot (`.github/dependabot.yml`) proposes weekly updates of the pinned GitHub Actions only.
It used to watch the Swift packages too, but that job never resolved `Package.swift`: Dependabot
routes a job through a proxy that only reaches the registries it knows, and refuses
`x.klarnacdn.net`, where Klarna's binary targets download from, with a `403` ("egress not
allowlisted"). No Dependabot registry type covers a plain download host, so the Swift side moved to
`.github/workflows/swift-package-update.yml`. Every Monday it runs `swift package update` on a
regular runner, within the ranges in `Package.swift`. When a pin moves, it opens or refreshes one
`build(deps): update Swift packages` pull request from `deps/swift-packages`, and CI vets it like
any other. It uses `TF_REPO_AUTOMATION_PAT` from the `release-please` environment, because a pull
request opened with `GITHUB_TOKEN` would start no CI. A major version bump still needs a manual
change to `Package.swift`. Run it on demand from Actions → Swift packages → Run workflow.

`.github/workflows/codeql.yml` scans **Swift**, the release scripts (**Python**) and the **workflows** (`actions`) on every pull
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
  (see [release.md](release.md#prerequisites-one-time-setup)), stored only as an **environment**
  secret. A repository secret is readable by a workflow pushed on any branch; an environment secret
  only by a job allowed to deploy to that environment.

## Repository settings

Repository settings, not code — a repository admin applies them once. `.github/CODEOWNERS` makes
`@UpStreamPay/pci-dss` the owner of every file; the team needs **write** access to the repository
for that to apply.

**`main` ruleset** (Settings → Rules → Rulesets):

- no deletion, no force-push, no bypass
- pull request required, **1 approval**, **review from a code owner**, approvals dismissed on a new push
- status checks, **strict** (branch up to date with `main`): `Library Tests`, `Demo App`,
  `Dependency review`, `CodeQL (swift)`, `CodeQL (python)`, `CodeQL (actions)`
- code scanning: CodeQL, blocking on high or critical security alerts and on errors

**`release tags` ruleset** on `refs/tags/v*` and `refs/tags/sdk-v*`: creation, update and deletion
restricted, bypass for the **repository admin** role only. SPM resolves a version from its `v*` tag,
so moving one changes the code every merchant gets. Both legitimate tag writes go out as
`TF_REPO_AUTOMATION_PAT`, an admin's token: release-please creating `sdk-vX.Y.Z` on `main`, and
`release.yml` creating `vX.Y.Z` on the binary-manifest commit (see
[release.md](release.md#two-tags-per-version)). Neither is ever moved. The GitHub Actions app is
deliberately **not** a bypass actor: `GITHUB_TOKEN` belongs to every workflow run, and a workflow on
any branch can ask for `contents: write`, so that bypass would let anyone with write access write a
release tag.

**`release-please` environment**: no reviewers, deployments from `main` only. It holds a copy of
`TF_REPO_AUTOMATION_PAT`, so only `release-please.yml` running on `main` can read it. Why this is a separate
environment from `release`: [release.md](release.md#why-two-environments-release-please-and-release).

**`release` environment**: required reviewers `@UpStreamPay/pci-dss`, self-review prevented,
deployments only from `sdk-v*` tags. It holds the `APPLE_SIGNING_*` secrets and the other copy of
`TF_REPO_AUTOMATION_PAT`. It must exist **before** a workflow naming it runs, otherwise GitHub
creates it with no protection — the same goes for `release-please`.

**Code security**: code scanning (CodeQL, default setup off — see [Dependencies](#dependencies)),
secret scanning and push protection on. On a private repository these need GitHub Advanced
Security.

**Actions** (Settings → Actions → General): the default `GITHUB_TOKEN` is read-only and workflows
cannot approve pull requests.
