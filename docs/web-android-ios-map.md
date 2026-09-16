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
| Error root | `abstract class PurseException` | `protocol PurseError` | Swift errors are values; a protocol lets session/API/checkout errors stay distinct types a caller can switch over. |
| Suspension codes | 11 (3 web codes dropped as DOM-only) | 11 *(PR 6)* | iOS follows Android for consistency across native platforms. **SDK-12263's AC says 14 and must be amended.** |
| BNPL total | `initial + (count−2)×recurring + final` — fixes a web double-count | same *(PR 5)* | Web's figure is wrong in a credit disclosure; iOS keeps web's field names and Android's arithmetic. **Raise a web bug.** |
| Partner discovery | `ServiceLoader` over `META-INF/services` | explicit `install()` *(PR 4)* | No `ServiceLoader` and no lazy class loading on this platform (stated in SDK-12264). Android already supports explicit install; iOS makes it the only path. |
| Google Pay / Apple Pay | `:partner-googlepay` | `PurseCheckoutApplePay` *(PR 4)* | Not a rename — a different partner integration entirely. Net-new work, not a port. |
| `PATCH` requests | sent as `POST` + `X-HTTP-Method-Override` | real `PATCH` *(PR 5)* | `HttpURLConnection` refuses `PATCH`; `URLSession` does not. |

## Vocabulary

| Web | Android | iOS |
|---|---|---|
| `mops` store | `paymentMethods` `StateFlow` | `paymentMethods` `@Published` *(PR 2)* |
| `PurseHeadlessCheckout.init(widgetData)` | `init(widgetData, lockedEnvironment, hooks, options, disabledMethods)` | *(PR 2)* |
| `teardown()` | `teardown()` | *(PR 6)* |
