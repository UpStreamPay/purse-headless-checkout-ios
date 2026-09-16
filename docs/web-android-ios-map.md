# Web ↔ Android ↔ iOS map

Cross-reference between `usp-widget` (web, the reference implementation),
`purse-headless-checkout-android` (the first native port) and this SDK. Update this file in the same
commit that adds or removes a divergence.

Web paths are under `usp-widget/packages/`. Android paths are under
`headless-checkout/src/main/kotlin/eu/purse/`.

## Core — landed

| Web | Android | iOS |
|---|---|---|
| `sdk/src/types.ts` (`Target`) | `core/environment/PurseEnvironment.kt` | `Core/Environment/PurseEnvironment.swift` |
| `sdk/src/types.ts` (`Partner` union) | `core/payment/Partner.kt` | `Core/Payment/Partner.swift` |
| `sdk/src/types.ts` (`Method` union) | `core/payment/Method.kt` | `Core/Payment/Method.swift` |
| `sdk/src/types.ts` (`VaultVendors`) | `core/vault/VaultVendor.kt` | `Core/Vault/VaultVendor.swift` |
| model card brands | `core/vault/CardBrand.kt` | `Core/Vault/CardBrand.swift` |
| model `vault.vendor_front_data` | `core/vault/SessionVault.kt` | `Core/Vault/SessionVault.swift` |
| model `protocols[…].configurations` | `core/payment/MethodConfiguration.kt` | `Core/Payment/MethodConfiguration.swift` |
| model `save_token_mode` | `core/payment/SaveTokenMode.kt` | `Core/Payment/SaveTokenMode.swift` |
| model `integrated_tokens[]` | `core/payment/IntegratedToken.kt` | `Core/Payment/IntegratedToken.swift` |
| `headless-checkout` base64 decode | `core/session/SessionCodec.kt` | `Core/Session/SessionCodec.swift` |
| model session decode | `core/session/LegacyPaymentSessionParser.kt` | `Core/Session/LegacyPaymentSessionParser.swift` |
| model `LegacyPaymentSession` | `core/session/LegacyPaymentSession.kt` | `Core/Session/LegacyPaymentSession.swift` |
| `sdk/src/API/payment-api.ts` | `core/api/PaymentApiClient.kt` | `Core/API/PaymentAPIClient.swift` |
| `partner-ui/.../initGuard.ts` | `core/api/InitGuard.kt` | `Core/API/InitGuard.swift` |
| `sdk/src/server-datetime-checker.ts` | `core/datetime/ServerDatetimeChecker.kt` | `Core/Datetime/ServerDatetimeChecker.swift` |
| `utils/error/error-codes.ts` | `core/error/PurseErrorCode.kt` | `Core/Error/PurseErrorCode.swift` |
| `utils/error/error.ts` | `core/error/PurseException.kt` | `Core/Error/PurseError.swift` |
| `sdk/src/API` error shape | `core/api/PaymentApiException.kt` | `Core/Error/PaymentAPIError.swift` |
| model `/validate` response | `core/payload/ValidationResult.kt` | `Core/Payload/ValidationResult.swift` |
| model `ItemPayload` | `core/payload/ItemPayload.kt` | `Core/Payload/ItemPayload.swift` |
| `sdk/src/API/types.ts` (`StatusStates`) | `core/payload/PaymentStatus.kt` | `Core/Payload/PaymentStatus.swift` |
| *(none — JS objects)* | *(none — `org.json.JSONObject`)* | `Core/JSON/JSONValue.swift` |

## Checkout — landed

| Web | Android | iOS |
|---|---|---|
| `mops/disabled.ts` | `checkout/payment/item/DisabledState.kt` | `Checkout/Payment/Item/DisabledState.swift` |
| mops recompute on `primaryReach` | `checkout/payment/item/MethodAvailability.kt` | `Checkout/Payment/Item/MethodAvailability.swift` |
| `mops/item-factory` | `checkout/payment/item/PaymentItem.kt`, `PaymentToken.kt` | `Checkout/Payment/Item/PaymentItem.swift` |
| `splitter/payment-splitter.ts` | `checkout/payment/split/PursePaymentSplitter.kt` | `Checkout/Payment/Split/PursePaymentSplitter.swift` |
| `splitter/types.ts` | `checkout/payment/split/{PaymentSplit,SplitSource,PrimarySource}.kt` | `Checkout/Payment/Split/SplitSource.swift` |
| secondaries token shape | `checkout/payment/secondary/SecondaryToken.kt` | `Checkout/Payment/Secondary/SecondaryToken.swift` |
| `secondaries/configs/*.ts` | `checkout/payment/secondary/SecondaryConfig.kt` | `Checkout/Payment/Secondary/SecondaryConfig.swift` |
| `secondaries` tokenization | `checkout/payment/secondary/SecondaryTokenizer.kt` | `Checkout/Payment/Secondary/SecondaryTokenizer.swift` |
| `plugins/generics/applepay/*` | *(none — Android ships Google Pay instead)* | `Sources/PurseCheckoutApplePay/` (net-new, not a port) |
| `plugins/partners/paypal/wallet/*` | `partner-paypal/…/wallet/{PaypalPlugin,PaypalMapper,PaypalCoordinator}.kt` | `Sources/PurseCheckoutPayPal/{PayPalPlugin,PayPalCoordinator}.swift` |
| `plugins/partners/klarna-installments/*` | `partner-klarna/…/klarna/{KlarnaPlugin,KlarnaMapper,KlarnaCoordinator}.kt` | `Sources/PurseCheckoutKlarna/{KlarnaPlugin,KlarnaCoordinator,KlarnaAuthorizationRegistry}.swift` |
| `item-factory/factories.ts` | `checkout/session/PaymentSessionBuilder.kt` | `Checkout/Session/PaymentSessionBuilder.swift` |
| `session/payment/payment.ts` | `checkout/session/PaymentSession.kt` | `Checkout/Session/PaymentSession.swift` |
| `headless-checkout.ts` | `checkout/PurseHeadlessCheckout.kt` | `Checkout/PurseHeadlessCheckout.swift` |
| `buildSecondaryPaymentToken` (saved-card balance) | `resolveSavedSecondaryBalances`/`resolveSavedSecondaryBalance` | `resolveSavedSecondaryBalances()`/`resolveSavedSecondaryBalance(_:api:)` in `Checkout/PurseHeadlessCheckout.swift` |
| `utils/error/error.ts` (thrown) | `checkout/PurseCheckoutException.kt` | `Checkout/PurseCheckoutError.swift` |
| `registration` stores | `checkout/payment/registration/RegistrationState.kt` | `Checkout/Payment/Registration/RegistrationState.swift` |
| wallet client + rename/delete/favorite/delete-all | `core/api/WalletApiClient.kt`, `checkout/wallet/WalletTokens.kt` | `Core/API/WalletAPIClient.swift`, `Checkout/Wallet/WalletTokens.swift` |
| `LoanProduct`/`LoanSimulation`/`simulateLoan(s)` | `core/payment/LoanSimulation.kt`, `checkout/simulation/LoanSimulator.kt` | `Core/Payment/LoanSimulation.swift`, `getSimulation`/`getSimulationMulti` on `PaymentAPIClient`, `simulateLoan`/`simulateLoans` on `PurseHeadlessCheckout` |
| `commons/PartnerUI/theming/*` | `partnerui/PurseTheme.kt`, `ThemeValues` | `PartnerUI/PurseTheme.swift` (`PurseTheme`, `CardFormTexts`) |

## PartnerUI — landed

| Web | Android | iOS |
|---|---|---|
| `commons/Plugin/types.ts` (`Plugin<Context>`) | `partnerui/PartnerUiPlugin.kt` | `PartnerUI/PartnerUIPlugin.swift` |
| `commons/PartnerUI/types.ts` | `partnerui/PartnerUiContext.kt` | `PartnerUI/PartnerUIPlugin.swift` (`PartnerUIContext`) |
| `plugins/index.ts` (`getPlugin`) | `partnerui/PluginRegistry.kt` | `PartnerUI/PluginRegistry.swift` |
| none | `partnerui/PluginHost.kt` | `PartnerUI/PluginHost.swift` |
| `partner-ui/src/events.ts` | `partnerui/PluginEvent.kt` | `PartnerUI/PluginEvent.swift` |
| payment-element events | `partnerui/PaymentOutcome.kt` | `PartnerUI/PluginEvent.swift` (`PaymentOutcome`) |
| `manageRedirection` shapes | `partnerui/redirect/RedirectAction.kt` | `PartnerUI/Redirect/RedirectAction.swift` |
| `manageRedirection` | `partnerui/redirect/RedirectionResolver.kt` | `PartnerUI/Redirect/RedirectionResolver.swift` |
| page navigation | `partnerui/redirect/RedirectionCheckoutActivity.kt` | `PartnerUI/Redirect/WebAuthRedirectPresenter.swift` |
| `plugins/generics/redirection` | `plugins/generics/redirection/RedirectionPlugin.kt` | `PartnerUI/Plugins/RedirectionPlugin.swift` |
| `plugins/vaults/purse/creditcard` | `plugins/vaults/purse/creditcard/CardPlugin.kt`, `CardMapper.kt` | `PartnerUI/Plugins/Card/CardPlugin.swift` |
| hosted-fields mount | `plugins/vaults/purse/creditcard/CardCoordinator.kt` | `PartnerUI/Plugins/Card/CardCoordinator.swift` |
| `headless-checkout-validation.ts` | `checkout/validation/PaymentValidator.kt` | `Checkout/Validation/PaymentValidator.swift` |
| `PurseHeadlessCheckoutHooks` | `checkout/PurseCheckoutHooks.kt` | `Checkout/Validation/PaymentValidator.swift` (`PurseCheckoutHooks`) |

## Divergences and why

| Topic | Android | iOS | Why |
|---|---|---|---|
| `teardown()` and plugin `destroyClient` | tracks every live plugin instance in `activePlugins`, calls `destroyClient` on each at teardown | calls none — no persistent plugin instance exists to call it on | iOS never retains a plugin across calls: each submit resolves and discards its own via `PluginRegistry.plugin(...)`, and each coordinator (`CardCoordinator`, `ApplePayCoordinator`, …) is a separate object the merchant already owns and releases with its own UI. There is currently no `PluginHost` implementation shipped at all on iOS (see the next row) — `destroyClient` has no call site to reach even if a future one wanted to invoke it. |
| A concrete `PluginHost` | `PurseHeadlessCheckout.host(item)` implements it | **not implemented yet, by any type** | Every coordinator (`CardCoordinator` etc.) takes `host: any PluginHost` as an init parameter, and every plugin test constructs a bare `PartnerUIContext` directly rather than going through a real host — real end-to-end use (the eventual Demo app) needs this seam built. Flagged, not silently worked around; tracked for the Demo app / SDK-12266 work. |
| Free-form JSON | `org.json.JSONObject` | `JSONValue` enum | `JSONObject` is a mutable reference type; Swift 6 needs a `Sendable` value type to cross an actor boundary. Also fixes decimal precision: numbers keep their literal text instead of going through `Double`. |
| Networking | blocking `HttpURLConnection`, callers hop to `Dispatchers.IO` | `async` `URLSession` | Nothing to offload — and nothing in the call path touches the main actor, so "no network on the main thread" is enforced by the compiler (SDK-12263). |
| `InitGuard` | `object` + `synchronized` + `CountDownLatch` | `actor` + `Task` | Same three behaviours (coalesce, retry, fast-reject); waiters await the leader's `Task` rather than a latch. |
| `ServerDatetimeChecker` | `@Volatile` fields | `actor` | Same. |
| Sealed types with `Other` | `sealed class` + `by lazy` known-list | `enum` + `.other(String)` | Android needs `by lazy` to dodge a sealed-object init-order NPE; a Swift enum has no such hazard, so lookup is a plain switch. |
| `InitGuard` on an exhausted **retryable** failure | stores `Entry.Spent` unconditionally | clears the key instead; only a non-retryable (4xx) failure is stored | Both types document fast-rejection as being for a *terminal* failure ("a 4xx is a definitive backend decision"). Storing a transport failure contradicts that: `shared` is process-wide, the key is stable across retries, and nothing evicts a spent entry — so losing signal for two seconds during `/init` kills that method for the life of the app process. **Android has the same defect against the same doc; report it.** |
| Unpadded base64 in `widget.data` | accepted (JDK *basic* decoder: `'='` "is accepted … but is not required") | accepted — padding is restored before decoding | `Data(base64Encoded:)` rejects any length that is not a multiple of 4, so without this a backend that strips padding yields a working Android checkout and `SESSION_MALFORMED` on every iOS device. Same blob must not get two verdicts. |
| `outcomeUnknown` for a request that never left the device | `status == null`, so an unusable URL or unencodable body reads as "the payment may exist" | additionally requires `requestSent` | The caller acts on `outcomeUnknown` by **spending the session**. Doing that for a call that provably sent no byte is wrong in the one direction that costs a shopper their order. Such an error is also not retryable — it fails identically every time. |
| `PaymentItem` | `sealed class` + 4 data classes | `enum` + 4 structs | A `switch` over the four kinds is exhaustive, so a fifth kind cannot compile until every dispatch site handles it. |
| Splitter | `class`, mutable, not thread-safe | `struct`, mutating methods | Value semantics; only ever touched on the main actor, so no `Sendable` question arises. |
| Item ordering | inherits JSON object order | ties broken by id | Swift dictionaries have no stable iteration order, so items with no `position` would otherwise shuffle between builds. |
| A plugin's `postValidation` throwing **after** a successful `/validate` | propagates raw; the catch never sets `validationConsumed`, so the session reads as still submittable | `postValidationFailed(result:underlying:)` carries the result, and the session is spent | `/validate` answered, so the payment exists — Klarna's `postValidation` throws on a declined authorization, which is the ordinary way to reach this. Leaving the session submittable invites a second `/validate` against an already-charged session, contradicting the invariant both ports state ("a declined payment spends the session"). **Android has the same defect; report it.** |
| Expiry watchdog and server clock | `startExpiryWatchdog` every 5 s; `isExpiredForServer` checked in `acquireSubmitLock` and `setSession` | watchdog ported; server clock checked in `acquireSubmitLock`, device clock kept in `setSession` | `ServerDatetimeChecker` existed here with **zero call sites** — nothing ever called `sync()`, so the offset stayed 0 and "server-corrected" meant the device clock. `setSession` stays synchronous (making it `async` would break every caller for a check that only pre-screens: the gate that reaches the PSP is the submit-time one). |
| `PluginEvent` / `pluginEvents` stream | coordinators dispatch events; the checkout clears recoverable states, deactivates methods, terminates the session, and re-exposes them; emits `PARTNER_UI_EVENT` | **not ported** — the orphaned public enum was removed | It had no producer and no consumer anywhere, so a merchant could never receive one. Shipping a public type that promises behaviour nothing implements is the scaffolding AGENTS.md forbids, and removing it later would be a breaking change. See `PartnerUIError.swift` for what building it would take. |
| POST redirects | `FormRedirectHtmlBuilder` renders an auto-submitting `<form>` and loads it | same, ported as `FormRedirectHTML` | `WKWebView.load(_:)` silently drops a request's `httpBody`, so the previous `URLRequest`-with-body approach reached the ACS with an empty POST and was answered 400 — every form-POST 3-D Secure challenge failed. Android hit the mirror-image problem with `WebView.postUrl` and its builder exists to say so. |
| `ASWebAuthenticationSession` vs the web view for a GET | always an in-app `WebView` | browser **only when it can observe the return**, else the web view | Below iOS 17.4 the session can only match a custom scheme, so a Universal Link policy had to pass `callbackURLScheme: nil` — matching nothing, leaving a completed 3-D Secure reported as a cancellation. The deployment target is iOS 16, so that was most devices. The web view watches every navigation itself and works everywhere; the browser's ACS advantage is kept wherever it actually functions. |
| `returnURLPrefix` | half of Android's `isReturnUrl`, alongside the widget-confirmation marker | same, now actually read | It was plumbed end to end here and consumed by nobody: a PSP that redirects to the merchant's configured return page (the common case) rendered it as just another allowed hop, and Cancel was the only exit — a completed payment reported as canceled. |
| `widgetConfirmationPaymentId` | base64url-decodes the `purse-redirection-data` JWT payload | same | iOS read a sibling `payment_id=` query parameter the server does not send, so it always returned `nil`; the test that covered it fabricated the URL shape, so it passed against an extractor that could never work in production. |
| Error root | `abstract class PurseException` | `protocol PurseError` | Swift errors are values; a protocol lets session/API/checkout errors stay distinct types a caller can switch over. |
| Suspension codes | 11 (3 web codes dropped as DOM-only) | 11 | iOS follows Android for consistency across native platforms. **SDK-12263's AC says 14 and must be amended.** |
| BNPL total | `initial + (count−2)×recurring + final` — fixes a web double-count | same *(PR #13)* | Web's figure is wrong in a credit disclosure; iOS keeps web's field names and Android's arithmetic. **Raise a web bug.** |
| Partner discovery | `ServiceLoader` over `META-INF/services` | explicit `install()` *(PR 4)* | No `ServiceLoader` and no lazy class loading on this platform (stated in SDK-12264). Android already supports explicit install; iOS makes it the only path. |
| Google Pay / Apple Pay | `:partner-googlepay` | `PurseCheckoutApplePay` *(PR 4)* | Not a rename — a different partner integration entirely. Net-new work, not a port. |
| `PATCH` requests | sent as `POST` + `X-HTTP-Method-Override` | real `PATCH` *(PR #13)* | `HttpURLConnection` refuses `PATCH`; `URLSession` does not. |
| Theming string parser (`ThemeValues`: colour/size/weight/family from CSS-like strings) | needed — Compose has no CSS-string reader | not ported — `PurseTheme` takes native `UIColor`/`UIFont`/`CGFloat` directly *(PR #13)* | Decided before writing any code (see "What changed" in the plan): no cross-platform merchant config exists to share, so the string layer would be pure overhead on iOS. |
| Theme → native field styling | `VaultStyles` (SecureFields Android) | `SecureFieldsStyle` (Secure Fields iOS) *(PR #13)* | Real native surface on both platforms — `PurseTheme.resolve()`'s `input`/`inputFocus`/`inputValid`/`inputInvalid` map directly onto it in `CardCoordinator`. |
| `CardFormTexts` (`label`/`helperText`/`requiredError`/`formatError`) | rendered by the Compose card form | **not rendered** *(PR #13)* — only `placeholder` has a native Secure Fields surface (`SecureFieldConfig`) | `CardCoordinator` exposes Secure Fields' bare views with no label/helper-text chrome of its own; the type is kept as data so a future rendering layer needs no new public API, not silently dropped. |
| Wallet API `WalletApiClient`/`WalletTokens` | blocking `HttpURLConnection` | `async` `URLSession`, same routes/headers *(PR #13)* | Same reasoning as `PaymentAPIClient`. |
| `LoanSimulator`/`LoanSimulation` | entity-scoped `POST /simulation/{entityId}/{partner}/{method}[/multi]` | same *(PR #13)* | `PaymentAPIClient.getSimulation`/`getSimulationMulti` reuse the existing `url:` override the transport already had. |
| `RegistrationState`, `register()`/`registrationOf()` | one map per checkout, resolved fresh at submit time | same *(PR #13)* | `PaymentValidator.execute(registrationByItem:)` enhances the payload centrally, the same seam Android's `enhanceWithRegistration` uses. |
| Wallet-brand vocabulary | n/a — Google Pay tokens carry no brand string PSPs need remapped this way | `ApplePayJSNetworkMapper` | Apple Pay JS network names (`"visa"`, `"masterCard"`, `"cartesBancaires"`) are not `PKPaymentNetwork.rawValue` (`"Visa"`, `"MasterCard"`, `"CartesBancaires"`, and `amex` → `"AmEx"`, not `"Amex"`). `PKPaymentNetwork(rawValue:)` on the JS string silently drops every network — caught by a test asserting against the real framework values, not by pattern review. Third instance of the same class of bug as the `CardBrand` mappings; see AGENTS.md. |
| PayPal approval-URL suppression | `PaypalMapper.isApprovalUrl`, consulted only inside `PaypalCoordinator` | `RedirectAction.isPayPalApprovalEcho`, consulted centrally inside `RedirectionResolver` | Android keeps this partner-specific because each coordinator resolves its own redirect. iOS mediates every plugin's redirect through one point (`PurseHeadlessCheckout.pendingRedirect(for:)`), so the check is centralized there instead of duplicated per future PSP plugin — the same class of problem the widget-confirmation-page suppression already solves the same way. |
| PayPal SDK module split | one Gradle module (`partner-paypal`) | `PurseCheckoutPayPal` depends on 3 upstream products (`CorePayments`, `PayPalWebPayments`, `PaymentButtons`) — none re-export each other, so all three are explicit dependencies | Verified by building the actual product, not assumed from `import PayPalWebPayments` alone: `CoreConfig`/`Environment` live in `CorePayments` and are not re-exported. |
| Klarna authorize callback | `KlarnaCoordinator` stashes a live `suspend () -> Boolean` in `PartnerUiContext.collected` (untyped `Map<String, Any>`); `KlarnaPlugin.postValidation` pulls it back out | `collected` is wire-safe `JSONValue` only, so the closure can't ride through it — `KlarnaAuthorizationRegistry` (an actor) holds it, keyed by a token stashed in `collected` instead | The Swift type doesn't allow Android's shortcut. First plugin that needed `postValidation` at all — Card, Apple Pay and PayPal all finish their native step *before* `/validate`. |
| Klarna distribution | Klarna's own CDN Maven repo (`https://x.klarnacdn.net/mobile-sdk/`), not Maven Central | real tagged GitHub releases (`klarna/klarna-mobile-sdk-spm`), binaries hosted on the same CDN but resolved normally by SwiftPM | Verified by a real `swift package resolve`, not assumed from the Android precedent — the iOS mirror turned out **not** to have the same distribution trap Secure Fields does. The sibling `klarna-mobile-sdk-basic-spm` is archived (`archived: true` on the repo itself) — checked via the GitHub API, not a search result. |
| Klarna product name | n/a | `PurseCheckoutKlarna` depends on the single `KlarnaPayments` product | Unlike PayPal's split, Klarna's manifest bundles the `KlarnaCore`/`KlarnaCoreWebView` *targets* inside the `KlarnaPayments` *product* — there is no separate `KlarnaCore` product, confirmed by reading the package's own `Package.swift` after a guessed dependency failed to resolve. |
| `Method` type name | `Method` | **`PaymentMethod`** | Foundation re-exports the Objective-C runtime's `Method` typedef. A merchant writing `-> Method` gets *"'Method' is ambiguous for type lookup"*, and cannot qualify it because the `PurseHeadlessCheckout` **class shadows the module of the same name**. Verified from a real consumer package, before and after. Web (TypeScript) and Android (Kotlin) have no such collision, so this is the one place naming parity had to give. |
| Following a redirect | `postValidation` opens an Activity | resolved after submit via `pendingRedirect(for:)` | Same as Android's reason: "follow a redirect" is `window.location` on web and needs nothing but the URL; natively it needs a presenter the pure protocol half must not own. |
| Presenting a GET redirect | in-app WebView | `ASWebAuthenticationSession` | Android's own docs warn that some ACS providers detect an embedded WebView and refuse to render the challenge, a card-network anti-phishing measure. `ASWebAuthenticationSession` is Safari, so it is not caught by that — a genuine iOS advantage. The POST cases still need a real `WKWebView`, exactly as on Android: no system browser can POST. |
| Partner module discovery | `ServiceLoader` | `PluginRegistry.install(_:)` | No `ServiceLoader`, no lazy class loading (stated in SDK-12264). Android already supports explicit install; iOS makes it the only path. |
| Secure Fields types | used directly | converted at the boundary | None of a Swift 5 module's public types are `Sendable` to us — `TokenizationResult`, and even `CardBrand`, a plain String enum. The coordinator converts inside the `nonisolated` delegate callback, before anything reaches the main actor. See AGENTS.md. |
| Secure Fields dependency | `securefields-android:1.4.2` from Maven | `from: "1.9.0"` over https | Was a revision pin: while `purse-securefields-ios` was private, its tags' binary-target release assets 404'd to SwiftPM under every auth method, so no tag resolved for anyone. The repository is public now and the artifact resolves, links and passes — the pin is gone. Note the URL must be `https://`, not `git@github.com:`, which authenticates regardless of visibility and so needs a key CI does not have. |
| Saved gift card name/expiry backfill from `/init` | `copy(name = it.name.ifBlank { parsed.name }, expirationDate = it.expirationDate ?: parsed.expirationDate…)` | not ported — `name`/`expirationDate`/`createdAt`/`pan`/`cvv` are `let`, not `internal(set) var` | Out of scope for this pass: iOS already sources the display name from the session's own `description.display_token` at build time (see `SavedSecondaryToken`'s doc comment), so Android's defensive fallback has nothing to guard against here. Revisit only if a real issuer is seen sending a blank name at session-build time. |
| Test-infra: a cached **terminal** `/init` failure | not applicable — Android has no equivalent global test double | `InitGuard.shared` caches a `spent` terminal failure indefinitely, keyed `sessionId:partner:method:amount` | A test driving a real terminal failure through `PaymentAPIClient.initPayment` must `await InitGuard.shared.reset()` before and after, or it poisons that key for any later test reusing the same `(sessionId, partner, method, amount)` — the identical hazard class `StubURLProtocol`'s host-keying already documents, one layer down. See AGENTS.md. |

## Vocabulary

| Web | Android | iOS |
|---|---|---|
| `mops` store | `paymentMethods` `StateFlow` | `paymentMethods` `@Published` |
| `PurseHeadlessCheckout.init(widgetData)` | `init(widgetData, lockedEnvironment, hooks, options, disabledMethods)` | `init(widgetData:lockedEnvironment:disabledMethods:)` |
| `teardown()` | `teardown()` | `teardown()` *(PR #14)* |
| `saveState()`/`restore()` | `CheckoutSavedState`, `PurseHeadlessCheckout.saveState()`/`.restore()` | `CheckoutSavedState`, `saveState()`/`PurseHeadlessCheckout.restore(_:)` *(PR #14)* |
| `apiClient()` as the one teardown choke point | `requireOpen()` called from `apiClient()`, `setSession`, `host()` | `requireOpen()` called from the `api` `get throws` computed property, `setSession`, `submitPayment`, `saveState` *(PR #14)* — iOS has no `host()` equivalent, see the divergence row below |
| `PurseErrorCodeCoverageTest` | one exception instance per code, several reused generically via an explicit `code` parameter | `PurseErrorCodeCoverageTests` *(PR #14)* — identical technique: `hookFailed`/`invalidTake`/`invalidSecondaryCard`/`secondaryTokenizationFailed`/`walletOperationFailed` each accept an explicit `PurseErrorCode`, so a code with no single dedicated case still gets a real carrier |
