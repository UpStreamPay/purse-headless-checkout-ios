# Payment methods by platform — web vs Android vs iOS

Source of truth, checked on 2026-09-17 against `purse-headless-checkout-android/docs/payment-methods-matrix.md`
and this SDK's own source.

- **Web**: `usp-widget/packages/partner-ui/src/plugins/{vaults,generics,partners}/index.ts` and
  `packages/headless-checkout/src/session/payment/mops/secondaries/configs/configs.ts`.
- **Android**: see the Android doc above.
- **iOS**: `Sources/PurseHeadlessCheckout/PartnerUI/{Plugins,Redirect}/*.swift` (card, redirection —
  built in), plus each optional product's plugin (`PurseCheckoutApplePay`, `PurseCheckoutPayPal`,
  `PurseCheckoutKlarna`) and `Checkout/Payment/Secondary/SecondaryConfig.swift`
  (`SecondaryConfigs`). Apple Pay, PayPal and Klarna need their product linked by the host app —
  there is no `ServiceLoader` equivalent, so explicit linking is the only path (see AGENTS.md).

Legend: ✅ shipped · 🧪 ported, not validated on a sandbox · ❌ not available · — not applicable to
the platform.

## How a method gets a plugin (same order on all three platforms)

| Step | Key | Web | Android | iOS |
|---|---|---|---|---|
| 1 | `configurations.vault.vendor` | `purse`, `pci_proxy` → hosted-fields card | `purse` → `CardPlugin` (SecureFields). `pci_proxy` ❌ | `purse` → `CardPlugin` (Secure Fields). `pci_proxy` ❌ |
| 2 | `configurations.template` | `redirection`, `sdpx`, `lyra`, `alma`, `applepay`, `googlepay` | `redirection` only | `redirection` only |
| 3 | `merchant_specifics.integration_mode = redirection` | → generic redirection | → generic redirection | → generic redirection |
| 4 | exact `(partner, method)` | 17 partners (table below) | `(klarna, installments)`, `(paypal, wallet)`, `(ingenico, googlepay)` | `(klarna, installments)`, `(paypal, wallet)` |
| 5 | method fallback | none | `googlepay` → `GooglePayPlugin` (any partner) | none |

Apple Pay has no pair/fallback step at all — it is resolved by `PaymentMethod.applePay`, one wire
value, configured per PSP variant (adyen/ingenico/default) from `/init` rather than by a
`(partner, method)` pair. See `ApplePayVariant` and the Apple Pay row below.

## Primary methods

### Cards

| Method | Web | Android | iOS | Notes |
|---|---|---|---|---|
| Card, Purse vault (`vault.vendor = purse`, any partner) | ✅ hosted fields | ✅ SecureFields Android, Compose form, 3-D Secure via redirect WebView | ✅ Secure Fields iOS, UIKit form (`CardCoordinator`), redirect-based 3-D Secure via `ASWebAuthenticationSession` | Saved-card CVV re-entry ✅ all three platforms. |
| Card, PCI Proxy vault (`vault.vendor = pci_proxy`) | ✅ | ❌ | ❌ | A `pci_proxy` saved token needing a CVV has no form on Android or iOS. |
| Card, PSP-hosted fields without a vault: aci, adyen, checkout, dalenys, hipay, ingenico, payline, stripe, worldpay `creditcard` | ✅ one plugin each | ❌ `NoPluginRegistered` | ❌ same | By design: native SDKs only pay cards through the Purse vault. |
| Card, `sdpx` template: sipsv2, sogenactif, mercanet | ✅ | ❌ | ❌ | |
| Card, `lyra` template: lyra, payzen, sogecommerce, systempay, scellius | ✅ Krypton form | ❌ | ❌ | |
| Card, external 3DS extras: payline, centralpay, axepta, worldpay, lyra family | ✅ via `vaultExtras` | ❌ | ❌ | Neither native SDK has a `vaultExtras` equivalent. |
| Any `creditcard` with `integration_mode = redirection` (e.g. ACI) | ✅ | ✅ generic redirection | ✅ generic redirection | |

### Wallets and x-pays

| Method | Web | Android | iOS | Notes |
|---|---|---|---|---|
| Google Pay (any gateway) | ✅ template | ✅ Play Services sheet, some gateways 🧪 | — | Android only; not planned for iOS. |
| Apple Pay (adyen/ingenico/default variants) | ✅ template | — | ✅ `PurseCheckoutApplePay`, `PKPaymentAuthorizationController` | Net-new work on iOS, not a port — Android has no precedent. No merchant-validation round trip needed (PassKit has none); configuration comes entirely from `/init`, same as web. |
| PayPal wallet, pay now | ✅ JS popup | ✅ PayPal Android SDK browser switch | ✅ `PurseCheckoutPayPal`, `PayPalWebCheckoutClient` browser switch | All three drop the echoed approval URL in `/validate`; iOS centralizes the check in `RedirectionResolver` rather than per-plugin — see the web↔Android↔iOS map. |
| PayPal wallet, saved token | ✅ | ✅ | ✅ | No CVV, captures on submit. |
| PayPal wallet, vaulting (create a token) | ✅ | ❌ | ❌ | Deferred on both native platforms. |
| PayPal BNPL (`bnpl`) | ✅ popup or redirection; has `ensureClientCompatibility` | ❌ dedicated; ✅ only if `integration_mode = redirection` | ❌ dedicated; ✅ only if `integration_mode = redirection` | |
| PayPal Fraudnet fingerprinting on redirection | ✅ | ❌ | ❌ | |

### BNPL, instalments, invoice

| Method | Web | Android | iOS | Notes |
|---|---|---|---|---|
| Klarna `installments` | ✅ Klarna JS SDK | ✅ native `KlarnaPaymentView`; `authorize()` after `/validate` | ✅ native `KlarnaPaymentView`; `authorize()` after `/validate` | iOS needed no host-app deep link scheme decision documented yet beyond accepting a `returnURL` parameter — see `KlarnaCoordinator`. |
| Alma (template `alma`) | ✅ Alma widget | ❌ | ❌ | Redirection mode would work on either native platform. |
| Riverty `invoice`, `3x`, `6x`, `9x`, `12x` | ✅ form (IBAN) + client-side simulation text | ❌ dedicated; ✅ if `template/integration_mode = redirection` | ❌ dedicated; ✅ if `template/integration_mode = redirection` | |
| Younited `installments` | ✅ | ❌ | ❌ | |
| Scalapay `cb3x-paybylink`, `cb4x-paybylink` | ✅ email form | ❌ | ❌ | |
| Loan simulation (`simulable` label, `POST /simulation`, `/multi`) | ✅ | ✅ `simulateLoan` / `simulateLoans` | ✅ same, Android's corrected arithmetic | Counts and amounts only, no per-instalment dates, on any platform. Web's total over-counts one instalment; iOS and Android both use the corrected math — see the map doc. |

### Other

| Method | Web | Android | iOS | Notes |
|---|---|---|---|---|
| HiPay MB Way (`mbway`) | ✅ phone form | ❌ | ❌ | |
| Any method with `template = redirection` (Fintecture, Bizum, Oney, Sequra, …) | ✅ | ✅ generic redirection, `partner_data.browser` from the WebView | ✅ generic redirection, `partner_data.browser` from `RedirectionPlugin` | |
| Saved-card management: rename, delete, favorite, delete all (`wallet_session`) | ✅ | ✅ | ✅ real `PATCH`, not `POST` + override | |
| Save a fresh card (`payment_preferences.registration`, `token_label`) | ✅ | ✅ | ✅ | Enhanced centrally in `PaymentValidator`, the same seam every plugin's payload already passes through. |

## Secondary methods (gift cards, loyalty, vouchers)

Same keys on all three platforms; each is a config, not a plugin.

| Key | CVV | Take policy | Web | Android | iOS |
|---|---|---|---|---|---|
| `illicado-giftcard` | always | none (splittable) | ✅ | ✅ | ✅ |
| `buybox-giftcard` | unless Storeland PAN | none | ✅ | ✅ | ✅ |
| `maxxing-loyaltycard` | no | max | ✅ | ✅ | ✅ |
| `ogloba-giftcard` | no | none | ✅ | ✅ | ✅ |
| `mybeezbox-giftcard` | no | none | ✅ | ✅ | ✅ |
| `easy2play-giftcard` | always | none | ✅ | ✅ | ✅ |
| `easy2play-voucher` | no | max | ✅ | ✅ | ✅ |
| `ancv-connect` (holder → poll every 10 s, 5 min) | no | max | ✅ | ❌ config not shipped; `pollForToken` / `classifyInitError` hooks exist | ❌ same — `SecondaryConfig` has `shouldPoll`/`classifyInitError` hooks a host can implement, but no built-in config |

| Other secondaries behaviour | Web | Android | iOS |
|---|---|---|---|
| Saved gift cards (`integrated_tokens` on a secondary) | ✅ | ✅ | ✅ — background balance resolution, sequential per `/init` (PR #11) |
| Keep a temporary gift card (registration) | ✅ | ✅ | ✅ |
| Host-registered issuer config | — (static table) | ✅ `SecondaryConfigs.register` | ✅ `SecondaryConfigs.register` — same extension point on both native platforms, the literal SDK-12261 AC |
| Splitter autofill middlewares (voucher → loyalty → primary) | ✅ | ❌ | ❌ |

## Reading the matrix

- **iOS covers the same ground as Android for everything shipped so far**: the Purse vault card,
  a redirection, and three native SDKs (Apple Pay in place of Google Pay, PayPal, Klarna).
  Everything else web supports is a PSP-hosted form living in the browser, with no native
  equivalent on either native platform, and not planned.
- **Saved methods, BNPL and theming have landed**: saved-card wallet management, save-at-submit
  registration and loan simulation all ported, plus `PurseTheme` (native `UIColor`/`UIFont`, mapped onto
  Secure Fields' own `SecureFieldsStyle` — no CSS-string parser, unlike Android's `ThemeValues`, since
  there is no cross-platform theme config to share).
- **Every row's badge now resolves.** `PurseAssets` ports web's `@upstreampay/assets`, so a method or
  card scheme has a CDN badge URL on all three platforms; rendering stays the integrator's job.
- **Whatever the method, the outcome is confirmable.** `awaitPaymentOutcome()` reads the session's own
  transactions, which is the only honest way to resolve a redirection method's return.
- **The three gaps Android and iOS share**, worth a deliberate decision rather than silent scope
  creep: `pci_proxy` cards, `ancv-connect`, and the PayPal BNPL / vaulting pair. The rest of the ❌
  column is "works if the merchant switches the method to `redirection` mode".
- Rows marked 🧪 are Android-only (Google Pay gateway variants); iOS has no equivalent open item at
  this level of granularity yet — every iOS row shipped so far has been validated by a real network
  stub test, not just ported.
