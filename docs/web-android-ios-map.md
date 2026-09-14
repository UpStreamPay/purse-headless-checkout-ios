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
| `item-factory/factories.ts` | `checkout/session/PaymentSessionBuilder.kt` | `Checkout/Session/PaymentSessionBuilder.swift` |
| `session/payment/payment.ts` | `checkout/session/PaymentSession.kt` | `Checkout/Session/PaymentSession.swift` |
| `headless-checkout.ts` | `checkout/PurseHeadlessCheckout.kt` | `Checkout/PurseHeadlessCheckout.swift` |
| `utils/error/error.ts` (thrown) | `checkout/PurseCheckoutException.kt` | `Checkout/PurseCheckoutError.swift` |

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
| BNPL total | `initial + (count−2)×recurring + final` — fixes a web double-count | same *(PR 5)* | Web's figure is wrong in a credit disclosure; iOS keeps web's field names and Android's arithmetic. **Raise a web bug.** |
| Partner discovery | `ServiceLoader` over `META-INF/services` | explicit `install()` *(PR 4)* | No `ServiceLoader` and no lazy class loading on this platform (stated in SDK-12264). Android already supports explicit install; iOS makes it the only path. |
| Google Pay / Apple Pay | `:partner-googlepay` | `PurseCheckoutApplePay` *(PR 4)* | Not a rename — a different partner integration entirely. Net-new work, not a port. |
| `PATCH` requests | sent as `POST` + `X-HTTP-Method-Override` | real `PATCH` *(PR 5)* | `HttpURLConnection` refuses `PATCH`; `URLSession` does not. |
| Wallet-brand vocabulary | n/a — Google Pay tokens carry no brand string PSPs need remapped this way | `ApplePayJSNetworkMapper` | Apple Pay JS network names (`"visa"`, `"masterCard"`, `"cartesBancaires"`) are not `PKPaymentNetwork.rawValue` (`"Visa"`, `"MasterCard"`, `"CartesBancaires"`, and `amex` → `"AmEx"`, not `"Amex"`). `PKPaymentNetwork(rawValue:)` on the JS string silently drops every network — caught by a test asserting against the real framework values, not by pattern review. Third instance of the same class of bug as the `CardBrand` mappings; see AGENTS.md. |
| PayPal approval-URL suppression | `PaypalMapper.isApprovalUrl`, consulted only inside `PaypalCoordinator` | `RedirectAction.isPayPalApprovalEcho`, consulted centrally inside `RedirectionResolver` | Android keeps this partner-specific because each coordinator resolves its own redirect. iOS mediates every plugin's redirect through one point (`PurseHeadlessCheckout.pendingRedirect(for:)`), so the check is centralized there instead of duplicated per future PSP plugin — the same class of problem the widget-confirmation-page suppression already solves the same way. |
| PayPal SDK module split | one Gradle module (`partner-paypal`) | `PurseCheckoutPayPal` depends on 3 upstream products (`CorePayments`, `PayPalWebPayments`, `PaymentButtons`) — none re-export each other, so all three are explicit dependencies | Verified by building the actual product, not assumed from `import PayPalWebPayments` alone: `CoreConfig`/`Environment` live in `CorePayments` and are not re-exported. |
| `Method` type name | `Method` | **`PaymentMethod`** | Foundation re-exports the Objective-C runtime's `Method` typedef. A merchant writing `-> Method` gets *"'Method' is ambiguous for type lookup"*, and cannot qualify it because the `PurseHeadlessCheckout` **class shadows the module of the same name**. Verified from a real consumer package, before and after. Web (TypeScript) and Android (Kotlin) have no such collision, so this is the one place naming parity had to give. |
| Following a redirect | `postValidation` opens an Activity | resolved after submit via `pendingRedirect(for:)` | Same as Android's reason: "follow a redirect" is `window.location` on web and needs nothing but the URL; natively it needs a presenter the pure protocol half must not own. |
| Presenting a GET redirect | in-app WebView | `ASWebAuthenticationSession` | Android's own docs warn that some ACS providers detect an embedded WebView and refuse to render the challenge, a card-network anti-phishing measure. `ASWebAuthenticationSession` is Safari, so it is not caught by that — a genuine iOS advantage. The POST cases still need a real `WKWebView`, exactly as on Android: no system browser can POST. |
| Partner module discovery | `ServiceLoader` | `PluginRegistry.install(_:)` | No `ServiceLoader`, no lazy class loading (stated in SDK-12264). Android already supports explicit install; iOS makes it the only path. |
| Secure Fields types | used directly | converted at the boundary | None of a Swift 5 module's public types are `Sendable` to us — `TokenizationResult`, and even `CardBrand`, a plain String enum. The coordinator converts inside the `nonisolated` delegate callback, before anything reaches the main actor. See AGENTS.md. |
| Secure Fields dependency | `securefields-android:1.4.2` from Maven | `from: "1.9.0"` over https | Was a revision pin: while `purse-securefields-ios` was private, its tags' binary-target release assets 404'd to SwiftPM under every auth method, so no tag resolved for anyone. The repository is public now and the artifact resolves, links and passes — the pin is gone. Note the URL must be `https://`, not `git@github.com:`, which authenticates regardless of visibility and so needs a key CI does not have. |

## Vocabulary

| Web | Android | iOS |
|---|---|---|
| `mops` store | `paymentMethods` `StateFlow` | `paymentMethods` `@Published` |
| `PurseHeadlessCheckout.init(widgetData)` | `init(widgetData, lockedEnvironment, hooks, options, disabledMethods)` | `init(widgetData:lockedEnvironment:disabledMethods:)` |
| `teardown()` | `teardown()` | *(PR 6)* |
