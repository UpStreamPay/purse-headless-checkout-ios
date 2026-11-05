# Card form: two levels

Same split as Stripe (PaymentSheet / `STPPaymentCardTextField`) and Adyen (Drop-in / Components):
a drop-in element that reports only what a checkout screen needs, and a lower level for full
control.

## `paymentElement` — drop-in

```swift
let element = checkout.paymentElement(for: item, listener: self, redirect: presenter)
PaymentElementView(element)   // label, field, helper text and error per field, drawn by the SDK
element.submit()              // tokenize → /init → /validate → redirect
```

`presenter` is a `WebAuthRedirectPresenter(policy:)`; without one, a redirect is not followed.

You get `isReady` (enable your pay button) and one `PaymentOutcome` per attempt, through the
listener. Field errors are rendered inside the form; the element does not expose them.

## `CardCoordinator` — full control

```swift
let host = try checkout.host(for: method)
try host.setAsPrimary()                      // the split must cover the amount, or nothing pays
let context = host.buildContext()
let card = CardCoordinator(
    host: host,
    tenantId: context.vaultTenantId ?? "",
    supportedBrands: context.configuration?.vault?.supportedBrands ?? [],
    token: context.token,
    options: context.options
)
let form = CardFormView(coordinator: card)   // or lay out `card.fieldViews` yourself
```

Observe `isFormValid`, `fieldStates`, `detectedBrands`, `selectedBrand`, `binLookupFailed`, and
`errorMessage(for:)` to draw your own messages. `selectBrand(_:)` picks the scheme on a co-badged
card. `fieldViews` size themselves — do not constrain their height.

Paying takes **two** calls, and a redirect is yours to follow:

```swift
try await card.submit()                           // tokenizes only
let result = try await checkout.submitPayment()   // /init + /validate
let outcome = try await checkout.presentRedirectIfNeeded(for: result, using: presenter)
```

Calling `submitPayment()` without `card.submit()` fails with "client-side validation failed …
tokenize the card form first".
