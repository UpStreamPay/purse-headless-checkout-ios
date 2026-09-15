# Purse Headless Checkout — iOS

[![CI](https://github.com/UpStreamPay/purse-headless-checkout-ios/actions/workflows/ci.yml/badge.svg)](https://github.com/UpStreamPay/purse-headless-checkout-ios/actions/workflows/ci.yml)

A headless iOS SDK for Purse payments. It owns the payment engine — session, payment methods, the
primary/secondary split, `/validate` — and leaves the checkout UI to you. Same concepts as the web
`usp-widget` headless SDK and the Purse Android SDK, in Swift.

> **In development.** The engine has landed (session, methods, split, reactive state); payment
> submission and the partner plugins have not. See
> [docs/README.md](docs/README.md) for what is built and what is next.

## Requirements

| | |
|---|---|
| iOS | 16.0+ |
| Swift | 6.0 (the package builds in Swift 6 language mode, strict concurrency) |
| Xcode | 16+ |

## What is in this repo today

| Area | Status |
|---|---|
| `widget.data` decode, session model | ✅ |
| Payment API client (`/init`, `/validate`, session read) | ✅ |
| `InitGuard` — coalescing, retry, fast-reject | ✅ |
| Server-clock-corrected expiry checking | ✅ |
| Error taxonomy (33 codes, shared with web and Android) | ✅ |
| Payment model, splitter, reactive state | ✅ |
| Plugin contract, registry, redirect resolution, `/validate` pipeline | ✅ |
| Card payment via Secure Fields (fresh, saved, CVV-only) | ✅ |
| Redirect presentation (redirect-based 3-D Secure, PSP pages) | ✅ |
| Gift cards, vouchers, loyalty (7 issuers + host-registrable) | ✅ |
| Apple Pay | ✅ (separate `PurseCheckoutApplePay` product) |
| PayPal | ✅ (separate `PurseCheckoutPayPal` product) |
| Klarna | ✅ (separate `PurseCheckoutKlarna` product) |
| Saved gift card background balance resolution | ✅ |
| Saved methods (rename, delete, favorite, delete-all), save-at-submit registration | ✅ |
| BNPL loan simulation | ✅ |
| Theming (`PurseTheme`, mapped onto Secure Fields' own style) | ✅ |
| `teardown()`/`isTornDown`, process-death state restoration, error-code coverage meta-test | ✅ |
| Observability — batched event bus, monitoring collector, privacy-audited payloads | ✅ |
| CI (build + test on PR), semantic versioning, release-please | ✅ (see `.github/workflows/`) |
| `PrivacyInfo.xcprivacy` (no required-reason APIs; data-type declaration pending a privacy sign-off) | ✅ |
| `PurseHeadlessCheckout.host(for:)` — the concrete `PluginHost` every coordinator runs through | ✅ |
| Demo app (`Demo/Demo.xcodeproj`) — builds, launches, exercises the engine end to end | ✅ (see below) |
| XCFramework signing/distribution, SwiftLint/SwiftFormat, docs | planned |

## Development

```sh
SIM_ID=$(xcrun simctl list -j devices available | python3 -c "
import json, sys
d = json.load(sys.stdin)['devices']
for rt, devs in sorted(d.items(), reverse=True):
    if 'iOS' not in rt: continue
    for dev in devs:
        if 'iPhone' in dev['name']:
            print(dev['udid']); raise SystemExit
")
xcodebuild test -scheme PurseHeadlessCheckout \
  -destination "platform=iOS Simulator,id=$SIM_ID" CODE_SIGNING_ALLOWED=NO
```

`swift build` does not work and is not meant to — the package targets iOS only, so always build for
a simulator destination.

Before changing anything, read [AGENTS.md](AGENTS.md): it lists the invariants that must not be
broken and why each one exists.

## Demo app

`Demo/Demo.xcodeproj` — a real, minimal UIKit app: session decode → `PurseHeadlessCheckout` →
`host(for:)` → `CardCoordinator` → `submitPayment()`, the same calls any merchant integration makes.
Builds and launches today (`xcodebuild build -project Demo/Demo.xcodeproj -scheme Demo -destination
"platform=iOS Simulator,id=$SIM_ID" CODE_SIGNING_ALLOWED=NO`); the embedded frameworks
(`PurseHeadlessCheckout.framework`, and `PurseSecureFields.framework` transitively) install and load
without a crash, confirmed on-device in the simulator, not just compiled.

**Running it against a real backend.** Copy `.env.example` to `.env`, put a real base64
`widget.data` in `WIDGET_DATA`, and `source scripts/load-env.sh` before building or launching Xcode.
With that set the Demo decodes your blob and talks to the real backend; with it empty it falls back
to a canned session and a stubbed `/validate` (`MockURLProtocol.swift`) so it still runs out of the
box. CI builds it in **Debug and Release** — it previously did not compile in Release at all, and
nothing built that configuration.

**What it still can't do.** The one card flow it exercises end to end without credentials is a saved
card that pays **without a CVV** (`merchant_specifics.pay_token_no_cvv`), because that is the only
path that mounts no Secure Fields form and calls no real Vault. Fresh-card entry, Apple Pay, PayPal
and Klarna each need real sandbox credentials (a Vault tenant id, an Apple Pay merchant id, a PayPal
client id, a Klarna client token). Wiring those in, and a release build actually authorizing a
sandbox payment, is what remains of SDK-12264/12266's acceptance criteria.

## License

MIT — see [LICENSE](LICENSE).

## Secure Fields: resolved from its tagged release

`Package.swift` takes [`purse-securefields-ios`](https://github.com/UpStreamPay/purse-securefields-ios)
as a normal version range (`from: "1.9.0"`) over **https**.

That is worth a note because it was not always possible. Every tag of that package rewrites its
manifest into an SPM **binary target** pointing at a GitHub release asset, and while the repository
was private that URL returned `404` to SwiftPM under every authentication method SwiftPM supports —
so no tag could be resolved by anyone, and this SDK pinned the source revision `5df309a` instead.
The repository is public now, the assets answer `200` unauthenticated, and the xcframework resolves,
links and passes the suite, so the pin is gone.

Two things that are easy to get wrong here:

- **Use `https://`, not `git@github.com:`.** SSH authenticates regardless of repository visibility,
  so an SSH URL still needs a key — which a CI runner does not have. That, and not the repository
  being private, is what was actually failing CI on every layer that links Secure Fields.
- **Wipe DerivedData when switching between a source pin and the binary artifact.** The stale
  `PurseSecureFields.framework` left behind produces `Undefined symbol:
  PurseSecureFields.SecureFieldsStyle.default.unsafeMutableAddressor`, which reads exactly like a
  broken release and is not one.

Still relevant to SDK-12264: this SDK's own release workflow was going to copy that binary-target
mechanism, so whoever builds it should decide deliberately whether the packaged XCFramework is
reachable by every consumer that needs it.
