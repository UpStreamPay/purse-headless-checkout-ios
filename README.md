# Purse Headless Checkout — iOS

[![CI](https://github.com/UpStreamPay/purse-headless-checkout-ios/actions/workflows/ci.yml/badge.svg)](https://github.com/UpStreamPay/purse-headless-checkout-ios/actions/workflows/ci.yml)

A headless iOS SDK for Purse payments. It owns the payment engine — session, payment methods, the
primary/secondary split, `/validate` — and leaves the checkout UI to you. Same concepts as the web
`usp-widget` headless SDK and the Purse Android SDK, in Swift.

> **In development.** The engine, the partner plugins and the payment flow have landed; packaging
> and the integration docs have not. The table below is the current state — see
> [docs/README.md](docs/README.md) for what is left.

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
| CI (build + test on PR), semantic versioning, release-please, codeowner-approved releases | ✅ (see [`docs/contributing/`](docs/contributing/)) |
| `PrivacyInfo.xcprivacy` (no required-reason APIs; data-type declaration pending a privacy sign-off) | ✅ |
| `PurseHeadlessCheckout.host(for:)` — the concrete `PluginHost` every coordinator runs through | ✅ |
| Payment elements — one `hasUI`/`isReady`/`submit()` shape per method, with a sealed `PaymentOutcome` | ✅ |
| Confirmation — from the merchant's backend. `sessionTransactions()`, `paymentStatus()`, `awaitPaymentOutcome()` are deprecated: the session read answers 401 to the client key | ⚠️ |
| Payment-method badges — `PurseAssets`, `iconURL(for:)`, `schemeAssets(for:)` (CDN URLs; you render them) | ✅ |
| Demo app (`Demo/Demo.xcodeproj`) — a playground and a shopper-facing checkout, both over real sessions | ✅ (see below) |
| Signed XCFrameworks on every release (core, Apple Pay, Klarna; PayPal plugin stays source) | ✅ (`.github/workflows/release.yml`) |
| SwiftLint/SwiftFormat, docs | planned |

## Installation

Swift Package Manager, `https://github.com/UpStreamPay/purse-headless-checkout-ios.git`. From the
first release after 1.0.0, tags resolve to signed XCFrameworks, like Secure Fields. Two consequences of a binary SDK:

- Public enums are not frozen: an exhaustive `switch` over one (`PaymentOutcome`,
  `PaymentSessionStatus`, …) needs an `@unknown default`, so a new case can ship in a minor release.
- `PurseEnvironment.test` and `.development` fall back to `.production` in a release-signed app
  (App Store, enterprise); they work in the simulator and in development and ad-hoc builds.

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

`Demo/Demo.xcodeproj` opens on a mode picker, against sessions minted by **alfred** (the `usp-widget`
dev server that holds the server-side Purse credentials a real merchant backend would).

| Mode | What it is |
|---|---|
| **Playground** | Session → pay → result, the same three screens as Android's `:app`: raw session and transaction dumps, an event log, a `widget.data` paste box, a manual capture tool. For working on the SDK. |
| **Checkout** | Basket → payment → confirmation. What a shopper sees, with the same SDK calls and none of the developer chrome. Its confirmation screen reads the session through alfred, standing in for the merchant backend: that read needs server credentials, and `widget.data`'s client key gets a 401. |

Checkout mode is styled to the Purse reference (`Demo/Sources/PurseDS.swift`): Albert Sans, an ink
call to action with Peppermint reserved for identity and selected states, and Lucide icons shipped
as template SVGs in the asset catalogue. Method names come from the **method**, not the partner, the
same way `usp-widget` does it — a shopper picks "Bank card", not "Ingenico". The playground keeps the
system font and its greyscale on purpose, so the two modes are told apart at a glance.

Bundled assets: [Albert Sans](https://fonts.google.com/specimen/Albert+Sans) under the SIL Open Font
License, and [Lucide](https://lucide.dev) icons under the ISC License. Both are demo-only and ship in
no SDK product.

```sh
cd ../usp-widget && npm run dev:alfred          # port 9001
cp .env.example .env                            # ALFRED_BASE_URL, blank ⇒ http://localhost:9001
source scripts/load-env.sh                      # must be sourced; see the script for why
xcodebuild build -project Demo/Demo.xcodeproj -scheme Demo \
  -destination "platform=iOS Simulator,id=$SIM_ID" CODE_SIGNING_ALLOWED=NO
```

`localhost`, not Android's `10.0.2.2` — that is an emulator alias for the host loopback, and the
Simulator shares the host's network stack. A physical device needs your machine's LAN IP.

**There is no offline path.** Without alfred the demo mints nothing; paste a `widget.data` on screen
1 instead. CI builds it in Debug and Release.

**What the demo still cannot exercise.** Apple Pay needs the In-App Payments entitlement on the
build alongside its merchant identifier, so it only works on a signed build and a real device; the
button renders regardless and the failure is reported, which is the honest result.

Everything else depends only on what the session offers: a method the Purse entity does not have
activated simply is not in the list. Klarna needs nothing from the app — its client token comes back
in the `/init` response (`plugin_result.logs.klarna_client_token`), so activating Klarna on the
entity is all it takes.

**Launch flags**, for smoke tests, never on by default. `-demo-autostart` mints a session and opens
the playground's pay screen. `-demo-checkout` opens checkout mode at its basket; with
`-demo-autostart` as well, it mints and lands on the payment page.


## License

MIT — see [LICENSE](LICENSE).
