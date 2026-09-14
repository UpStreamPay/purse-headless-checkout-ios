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
| Card payment via Secure Fields, 3-D Secure | blocked — see below |
| Apple Pay, PayPal, Klarna, redirection, gift cards | planned |
| Saved methods, BNPL, theming, hooks | planned |
| XCFramework distribution, monitoring, docs | planned |

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

## License

MIT — see [LICENSE](LICENSE).

## Known blocker: Secure Fields cannot be consumed from SPM yet

Card entry depends on [`purse-securefields-ios`](https://github.com/UpStreamPay/purse-securefields-ios),
which publishes each tag as an SPM **binary target** pointing at a GitHub release asset:

```
https://github.com/UpStreamPay/purse-securefields-ios/releases/download/v1.8.0/PurseSecureFields.xcframework.zip
```

The asset exists and is correctly uploaded — but the repository is **private**, and that URL form
returns `404` to SwiftPM. Verified: unauthenticated `404`; HTTP basic auth with a valid token (what
`--netrc-file` sends) `404`; only the REST endpoint
`/repos/…/releases/assets/<id>` with `Accept: application/octet-stream` returns `200`, and SwiftPM
does not use it. So `swift package resolve` fails for **any** consumer, including this SDK and any
merchant app.

Until it is fixed, this package does not declare the dependency and ships no card plugin.

Ways out, in rough order of cost — this is a call for the team that owns that repo:

1. Make the repository (or just its releases) public. The asset URL then resolves for everyone.
2. Host the XCFramework somewhere that honours basic auth or a token — S3, Artifactory, GitHub Packages.
3. Publish the tag as a **source** package for private consumers instead of a binary target.

Relevant to SDK-12264, whose acceptance criteria require both an XCFramework over SPM *and* a
documented private-repo authentication procedure. As published, those two cannot both hold.
