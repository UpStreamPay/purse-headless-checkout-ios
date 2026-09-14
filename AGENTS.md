# Working on purse-headless-checkout-ios

The Purse Headless Checkout SDK for iOS. It owns the *concept of a Purse payment* — session,
methods, split, `/validate` — and lets a merchant build their own checkout UI on top.

## Build & verify

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

`** TEST SUCCEEDED **` is the acceptance bar. `swift build` alone does **not** work and is not
meant to: the package declares iOS only, so a host-macOS build fails on availability. Always build
for a simulator destination.

## This is a port, not a design

Three implementations of one engine exist. In order of authority:

| | Where | Role |
|---|---|---|
| web | `usp-widget/packages/headless-checkout` | The reference implementation. Naming comes from here. |
| Android | `purse-headless-checkout-android` | The native port. Its `docs/web-android-map.md` already solved every web→native translation. |
| iOS | this repo | Follows Android, re-deciding only what is genuinely Android-specific. |

**Before writing a type, find its Android counterpart and read it.** Nearly every question
("should this throw or log?", "what happens to collected data on `setSession`?") is already answered
there, usually with a comment saying why. Re-deriving an answer that exists is how the three SDKs
drift apart.

Every file carries a three-line header saying what it mirrors:

```swift
// Web: packages/sdk/src/types.ts (`Partner` union)
// Same: known wire values.
// Differs: enum with `.other(String)`.
```

Keep it accurate. `Differs:` is the interesting line — it is the record of a decision.

## Key design invariants — do not break

### Amounts never touch a binary floating-point type
`JSONValue.number` stores the **literal source text**, and amounts are `Decimal`. `42.50` through a
`Double` is `42.499999999999996`. The splitter works in integer cents. There is a test pinning this
(`JSONValueTests.decimalsSurviveTheRoundTripExactly`); if it fails, do not "fix" it by loosening the
comparison.

### `outcomeUnknown` is not a failure
`PaymentAPIError.outcomeUnknown` (no HTTP status came back) means the `/validate` **may have
reached the server**, so the payment may exist. Never report it to the shopper as a failed payment —
the merchant reconciles with the session status instead. Getting this wrong double-charges people.

### The session decode is deliberately permissive
`LegacyPaymentSessionParser` validates exactly two things: `id` and `expiration_date` must exist.
That mirrors web's `checkSessionFormat` on purpose. An unknown partner or method must round-trip
through `.other(String)`, never fail the decode — otherwise a backend rollout breaks every shipped
app. Do not add "helpful" strictness here.

### Expiry is checked against server time
`ServerDatetimeChecker` corrects for a wrong device clock. A failed sync is swallowed and the
checker falls back to the local clock — a payment must never be blocked because a clock-sync call
timed out.

### `InitGuard` coalesces, and a 4xx is final
Concurrent duplicate `/init`s share one request; 5xx and transport failures retry; a 4xx is a
definitive backend decision and is never retried, and an immediate repeat of it is fast-rejected
with the original error. Keyed on session + partner + method + **amount**, so an amount-driven
re-init is a different call.

### Error codes are a shared vocabulary
`PurseErrorCode` raw values match web and Android exactly. `ErrorTaxonomyTests.theCodeSetMatchesAndroid`
pins the whole set. Adding a code means adding it on the other platforms too, or explaining in the
`Differs:` header why it is iOS-only.

## Concurrency

Swift 6 language mode, strict concurrency, and it currently compiles clean — keep it that way.

- Networking is `async` on `URLSession` and touches no actor. That is what keeps SDK network calls
  off the main thread *by construction* rather than by convention (SDK-12263).
- Shared mutable state is an `actor` (`InitGuard`, `ServerDatetimeChecker`), not a lock.
- `ISO8601DateFormatter` is **not** `Sendable`. It is built per call in `ISO8601Date.parse` rather
  than cached in a static. Do not "optimise" that into a shared instance.
- The public checkout object will be `@MainActor` + `ObservableObject`. UI state belongs on the main
  actor; nothing else does.

### Crossing the Swift 5 boundary to PurseSecureFields

`PurseSecureFields` is a Swift 5 module. **None of its public types are `Sendable` to us** — not
`TokenizationResult`, not even `CardBrand`, which is a plain `String` enum. Swift 5 modules get no
implicit `Sendable` conformance across the boundary, so any of its values crossing an isolation
boundary is a hard error under Swift 6.

The rule that follows, verified by building it against the real SDK:

**Convert to our own `Sendable` type inside the `nonisolated` delegate callback, before hopping to
the main actor.** Never capture one of its types in a main-actor closure, never store one in a
`Sendable` struct, never hand one to a continuation.

```swift
nonisolated func secureFieldsDidTokenize(_ result: TokenizationResult) {
    let tokenization = CardTokenization(            // ← our type, Sendable, built here
        vaultFormToken: result.vaultFormToken,
        bin: result.bin,
        selectedNetworkWireValue: result.selectedNetwork?.rawValue
    )
    MainActor.assumeIsolated { resume(.success(tokenization)) }
}
```

`assumeIsolated` is sound here and not a wish: every delegate callback arrives on the main thread.
The SDK hops through `DispatchQueue.main.async` itself before touching the delegate
(`SecureFieldsManager.swift:371` for the BIN lookup, `:608` for tokenization) and the rest fire from
UIKit event paths. If that ever changes, this bridge breaks — so it is pinned here.

**Do not reach for `@preconcurrency import`.** The compiler will suggest it, and it downgrades these
errors to warnings, which buys nothing: the conversion has to happen anyway, because a dependency's
types have no business in our public surface. A Secure Fields version bump must not be able to
change the checkout's API by accident, and the brand vocabularies differ regardless (`AMEX` vs
`AMERICAN_EXPRESS`), so the mapping is mandatory on its own merits.

## What NOT to do

- **Do not add a second observation mechanism.** One `ObservableObject` with `@Published`. Not
  `@Observable` (raises the deployment target), not a parallel `AsyncStream` of state.
- **Do not use `JSONSerialization`'s `[String: Any]`** for anything that crosses a concurrency
  boundary — it is not `Sendable`. That is what `JSONValue` is for.
- **Do not add a `baseURL` parameter to any public config.** URLs come from `PurseEnvironment` as
  `https://` literals, so a host cannot misconfigure the transport. Same rule as securefields.
- **Do not put a raw amount, PAN, personal data or transaction id in a monitoring payload.** Not
  even in a `DisabledState` message — that is why only the *code* is emitted.
- **Do not scaffold for a later PR.** Partner products (Apple Pay, PayPal, Klarna) land with their
  plugins, not before. Empty targets break the build and rot.
- **Do not make the parser stricter** (see above).

## Adding a payment method

1. Add the wire value to `Method` (or let it fall through to `.other`).
2. Decide whether it needs a plugin at all — redirect methods are covered by the generic template.
3. If it brings a partner SDK, it is a **separate SPM product**, registered explicitly by the
   merchant. There is no `ServiceLoader` on this platform; that is a deliberate divergence from
   Android, recorded in the module layout docs.
4. Mirror the Android plugin's `/init` timing and failure modes — `docs/plugins/` there is per-PSP.

## Repo layout

```
Sources/PurseHeadlessCheckout/
  Core/        session decode, Payment API client, environments, enums, errors   (Android: eu.purse.core)
  PartnerUI/   plugin contract, redirect machinery, card + redirection plugins   (Android: eu.purse.partnerui)
  Checkout/    PurseHeadlessCheckout, splitter, validate pipeline, elements      (Android: eu.purse.checkout)
Tests/PurseHeadlessCheckoutTests/
scripts/       generate-version.sh (git tag → SDKVersion.swift), load-env.sh
```

Dependency direction: `Checkout → {PartnerUI, Core}`, `PartnerUI → Core`, never back. `PartnerUI`
reaches the engine only through the `PluginHost` protocol.

## Versioning

The version lives in the git tag and nowhere else. `scripts/generate-version.sh` stamps
`SDKVersion.swift`; the checked-in value is `0.0.0-SNAPSHOT`. Releases are conventional-commit
driven through release-please.
