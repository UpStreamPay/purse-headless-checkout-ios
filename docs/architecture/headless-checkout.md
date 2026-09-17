# Headless checkout architecture

This SDK is a **headless** port of Purse's web `usp-widget`, following the Kotlin port in
`purse-headless-checkout-android`. It owns the concept of a Purse payment and lets a merchant build
their own checkout UI on top.

## Layers

One SPM product is the engine; partner SDKs that a card-only merchant should not have to embed are
separate products.

```
PurseHeadlessCheckout      the engine; card + redirection plugins built in
PurseCheckoutApplePay      optional (PassKit)
PurseCheckoutPayPal        optional (PayPal iOS SDK)
PurseCheckoutKlarna        optional (Klarna Mobile SDK)
```

Inside the engine, three directories mirror Android's three packages, which in turn mirror the web
packages:

| Directory | Android package | Mirrors web | Responsibility |
|---|---|---|---|
| `Core/` | `eu.purse.core` | `sdk` + `model` + `common` | Payment API client, environment targets, the `Partner`/`Method`/`VaultVendor`/`CardBrand` enums, `MethodConfiguration`, the raw `LegacyPaymentSession` DTO and its base64 `widget.data` decode, the typed `ItemPayload`/`ValidationResult`. No orchestration. |
| `PartnerUI/` | `eu.purse.partnerui` | `partner-ui` | The plugin lifecycle contract, the shared redirect machinery, and the two plugins every merchant gets: Purse-vault card (wrapping `PurseSecureFields`) and the generic redirection template. |
| `Checkout/` | `eu.purse.checkout` | `headless-checkout` | `PurseHeadlessCheckout`: session state, the built payment model, the splitter, the plugin-driven create-payment pipeline, payment elements. |

Dependency direction: `Checkout → {PartnerUI, Core}`, `PartnerUI → Core`, never back. `PartnerUI`
reaches the engine only through the `PluginHost` protocol, implemented by
`PurseHeadlessCheckout.host(item)` — the same seam Android uses to keep its `partnerui` package
from depending on `checkout`.

## The Purse-payment concept

1. **Session (V2).** A merchant backend hands the app a base64 `widget.data` blob wrapping
   `{ api_key, api_url, environment, entity_id, payment_session }`. `SessionCodec.decode`
   canonicalizes it to a `LegacyPaymentSession`; there is no separate V2 domain model.
2. **Build.** `PaymentSessionBuilder` turns `protocols.{partner}.{method}` into a
   means-of-payment list, applying the availability rules.
3. **Split.** One primary + N secondaries, in **integer cents**. Secondaries (gift cards)
   are drawn down first; the primary absorbs what is left.
4. **Create payment.** For each split, resolve its plugin, `preValidation` → item payload,
   `POST` all of them to `/validate`, then dispatch the result back to each plugin's
   `postValidation`. The Payment API is `{root}/{entityId}/sessions/{sessionId}/init|validate`.

## Amount units

Amounts in a session are decimal major-currency-unit values (`payment_min_amount: 0.01`), carried as
`Decimal` and parsed from the JSON **literal text**, never through `Double`. The splitter will work
in integer cents internally. See the invariant in [AGENTS.md](../../AGENTS.md).

## Environments

`PurseEnvironment` carries the four tiers and derives every root from one host, so telemetry and
clock-sync can never point at a different tier than payments. There is deliberately no `baseURL`
parameter in any public configuration: the URLs are `https://` literals, so a host cannot
misconfigure the transport.

A release build should pass a locked environment rather than trusting whatever the session declares.
