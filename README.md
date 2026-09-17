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
| CI (build + test on PR), semantic versioning, release-please | ✅ (see `.github/workflows/`) |
| `PrivacyInfo.xcprivacy` (no required-reason APIs; data-type declaration pending a privacy sign-off) | ✅ |
| `PurseHeadlessCheckout.host(for:)` — the concrete `PluginHost` every coordinator runs through | ✅ |
| Payment elements — one `hasUI`/`isReady`/`submit()` shape per method, with a sealed `PaymentOutcome` | ✅ |
| Confirmation — `sessionTransactions()`, `paymentStatus()`, `awaitPaymentOutcome()` over a typed `PaymentSessionStatus` | ✅ |
| Payment-method badges — `PurseAssets`, `iconURL(for:)`, `schemeAssets(for:)` (CDN URLs; you render them) | ✅ |
| Demo app (`Demo/Demo.xcodeproj`) — a playground and a shopper-facing checkout, both over real sessions | ✅ (see below) |
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

`Demo/Demo.xcodeproj` opens on a mode picker, against sessions minted by **alfred** (the `usp-widget`
dev server that holds the server-side Purse credentials a real merchant backend would).

| Mode | What it is |
|---|---|
| **Playground** | Session → pay → result, the same three screens as Android's `:app`: raw session and transaction dumps, an event log, a `widget.data` paste box, a manual capture tool. For working on the SDK. |
| **Checkout** | Basket → payment → confirmation. What a shopper sees, with the same SDK calls and none of the developer chrome. Its confirmation screen resolves the outcome with `awaitPaymentOutcome()` rather than asking alfred, because that is the only path a real merchant has. |

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

**What still needs credentials this repo does not have.** Apple Pay's `/init` answers 400 without a
real merchant id, and the sheet needs an entitlement — the button renders and the failure is
reported, which is the honest result. Klarna needs a live client token. Everything else runs: the
saved card, the redirection methods, gift-card split, loan simulation, `setSession`, teardown.

**Launch flags**, for smoke tests, never on by default. `-demo-autostart` mints a session and opens
the playground's pay screen. `-demo-checkout` opens checkout mode at its basket; with
`-demo-autostart` as well, it mints and lands on the payment page.


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

Still relevant here: this SDK's own release workflow was going to copy that binary-target
mechanism, so whoever builds it should decide deliberately whether the packaged XCFramework is
reachable by every consumer that needs it.
