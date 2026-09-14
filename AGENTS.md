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

### A plugin's `postValidation` cannot hold a closure from its own coordinator

Android's `PartnerUiContext.collected` is an untyped `Map<String, Any>`, so a coordinator can stash
a live `suspend () -> Boolean` callback in it and the plugin's `postValidation` pulls it back out.
Ours is `[String: JSONValue]` — wire-safe on purpose, so nothing non-`Sendable` (or non-JSON at all)
can ride through it. A closure cannot go in.

Klarna is the first plugin whose shape needs this: `postValidation` must call Klarna's own
`authorize()` on the live widget, but it runs as a **fresh** `PartnerUIPlugin` value with no
reference to the `KlarnaCoordinator` that prepared that widget. The fix is a small in-product actor
(`KlarnaAuthorizationRegistry`) that the coordinator registers its closure into, keyed by an opaque
token; the coordinator stashes only that token — a plain string — in `collected`, and
`postValidation` looks the closure up once and removes it. Reach for the same pattern for any future
plugin whose native step must run *after* `/validate`, not before.

## Tests: the stub is global, suites are not

swift-testing runs **suites in parallel**, and `StubURLProtocol` holds process-wide state. Handlers
are therefore keyed by **host**, and each suite that stubs the network must own a host no other
suite uses — pick a different `PurseEnvironment` tier if you need one. All four real tiers are
claimed: `SubmitPaymentTests` uses sandbox and test (one suite each, in the same file),
`CoPaymentTests` uses development, `SavedSecondaryBalanceTests` uses production. Once a tier is
taken, the way out is a fictional host instead, not squeezing onto someone else's tier:
`PayPalTests`, `KlarnaTests`, `CardPluginTests`, `LoanSimulationTests` and `RegistrationTests` build
their own `PaymentAPIClient`/`PartnerUIContext` directly against a made-up `apiRoot` — `PaymentAPIClient`
takes any root string, so this sidesteps the tier limit entirely. `WalletTests` does the analogous
thing for a **full** `PurseHeadlessCheckout` via `walletAPIRootOverride:` (a test-only init
parameter, same seam `urlSession:` already is) — proof that "all tiers are taken" is never actually
a blocker, only a prompt to make the thing under test accept its own root.

Getting this wrong does not fail loudly: the other suite's response arrives instead of yours, and
the test fails with a confusing assertion about the wrong body — including a nonsensical-looking
value that turns out to be a *different* suite's fixture. It has already cost four debugging rounds.
`@Suite(.serialized)` only serializes *within* a suite — it does nothing across them.

**`InitGuard.shared` has the identical hazard, one layer down.** It is a process-global singleton
keyed by `sessionId:partner:method:amount`, and a **terminal** `/init` failure is cached there
(`spent`) indefinitely — never evicted on failure, only on success or LRU capacity. A test that
deliberately drives a real terminal failure through `PaymentAPIClient.initPayment` poisons that key
for any later test that happens to reuse the same `(sessionId, partner, method, amount)` — reset it
around such a test: `await InitGuard.shared.reset()` before, and in a `defer` after.

## Redirects

Only **redirect-based** flows are in scope, redirect-based 3-D Secure included — it is an ordinary
redirection and gets no special path. A PSP that requires its own **embedded** 3-D Secure SDK (a
challenge rendered in-process) needs a partner plugin of its own; do not try to bend the redirect
presenter into one.

`RedirectPolicy` is a security boundary, not a convenience:

- **`https` only.** A challenge chain never legitimately needs `http`, `file`, `javascript` or
  another app's scheme, and allowing them turns a redirect into an exfiltration path.
- **Reaching the return is `returned`, never success.** The final redirect is built server-side and
  can land on a URL the client cannot read. The real outcome lives on the session. `RedirectOutcome`
  deliberately has no `success` case — keep it that way.
- A `WKNavigationDelegate` method whose signature is a near-miss **compiles, is never called, and
  silently disables the allowlist**. `decisionHandler` is `@escaping @MainActor @Sendable`.

## Never cast between vocabularies that merely look alike

Three separate near-identical-looking string vocabularies have bitten this codebase so far:
`CardBrand` (Payment API) vs Secure Fields' own `CardBrand` (`AMEX` vs `AMERICAN_EXPRESS`), and now
Apple Pay JS network names vs `PKPaymentNetwork.rawValue` (`"visa"`/`"Visa"`, and `amex`/`"AmEx"` —
not even a consistent capitalisation rule). Every one of these compiles as a raw-value cast and
fails silently at runtime: the value comes back `nil`, the field is just dropped from the request,
and nothing in the type system stops it. A test that only checks "some non-nil supportedNetworks
array" would have shipped this.

**The check that catches it**: compare against the real framework's actual values (print them, or
assert against literal string constants pulled from the SDK), never against what the naming pattern
suggests. A `.visa == .visa` test proves nothing if both sides were built with the same wrong
assumption.

If you introduce a new mapping between an external vocabulary and ours, write it as an explicit
`switch`/dictionary with a comment saying which two vocabularies it bridges, and add one test that
would fail if `rawValue` had been cast directly instead.

## Third-party vendor SDKs: verify before writing plugin code

Before writing a line of plugin code against a vendor SDK (PayPal, Klarna, and whatever comes
after), do the same three checks that caught real problems with Secure Fields and PayPal:

1. **Does the package actually resolve?** `swift package resolve` against the real dependency URL,
   in a throwaway scratch package — not a search result, not the vendor's own docs. Secure Fields'
   tagged releases do not resolve at all (see the README); PayPal's do.
2. **Which products does it actually export, and from where?** Don't assume `import Foo` gives you
   everything the vendor's own sample code imports. PayPal's `CoreConfig`/`Environment` live in
   `CorePayments`, a separate product from `PayPalWebPayments` that is not re-exported — this only
   surfaced by building the actual `PurseCheckoutPayPal` product target directly
   (`xcodebuild build -scheme PurseCheckoutPayPal`), not by building the umbrella scheme, which
   silently didn't compile it.
3. **Is its concurrency mode Swift 5 or 6, and does a vocabulary need mapping?** Assume a
   delegate-based vendor SDK is non-`Sendable` until proven otherwise (PayPal's `CoreSDKError` and
   `PayPalWebCheckoutResult` are), and check every delegate callback's exact parameter types — a
   near-miss there (e.g. expecting `any Error` when the real signature takes a concrete
   `CoreSDKError`) fails to conform to the protocol at compile time, which is at least loud; the
   vocabulary-casting kind of bug (see above) is not.

Always build the specific product's own scheme, not just the umbrella one — an unbuilt target in a
multi-product package does not fail the umbrella build.

**A vendor SDK's own products table can mislead by naming pattern.** Klarna's manifest has no
`KlarnaCore` *product* at all — `KlarnaCore` is only a *target*, bundled inside the `KlarnaPayments`
product alongside `KlarnaCoreWebView`. Guessing a product name from a target/module name you see in
an `import` line is exactly the mistake point 2 above warns about; read the package's own
`Package.swift` (`curl` the raw tag, or read it after `swift package resolve` has fetched it).

**When a vendor SDK ships no public source** (a binary xcframework, like Klarna's), its real Swift
API — exact method signatures, spellings, deprecations — is not documentation, it's the
`.swiftinterface` file SwiftPM already downloaded: after a scratch `swift package resolve`, find it
under `.build/artifacts/<package>/<product>/*.xcframework/*/*.framework/Modules/*.swiftmodule/*.swiftinterface`.
This is how Klarna's `finalise` (British spelling, not `finalize`) and the exact
`KlarnaPaymentEventListener` callback signatures were confirmed — a docs page or a guessed signature
would not have caught either.

**The same discipline applies to our own dependencies, not just PayPal/Klarna.** `PurseTheme`
(SDK-12262) was designed against an *assumed* gap — "Secure Fields has no styling API, so theming
has no real integration point yet" — until its actual `SecureFieldsConfig.swift` was read and turned
out to already carry a real `SecureFieldsStyle` (font/colors/per-state overrides) and
`SecureFieldsFieldsConfig` (per-field placeholder/accessibility label). The assumption would have
shipped `PurseTheme` as an inert data type with no wiring; reading the real dependency instead turned
it into a working feature. The inverse also happened in the same PR: `CardFormTexts.label`/
`helperText`/`requiredError`/`formatError` really do have no Secure Fields surface (only
`placeholder` and `accessibilityLabel` exist per field) — confirmed by reading the same file, not
assumed either way, and documented on the type itself rather than silently wired to nothing.

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
