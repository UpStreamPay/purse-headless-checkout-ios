# Documentation

A headless iOS SDK for Purse payments: it owns the payment engine (session, methods, split,
`/validate`) and lets you build the checkout UI. Same concepts as the web `usp-widget` headless SDK
and the Android SDK, in Swift.

> **Status: in development.** The SDK itself is feature-complete for everything in scope: session,
> payment model, split, submit, the partner plugins, confirmation, observability and lifecycle. What
> is left is packaging and the integration pages below marked *not written* — see
> [Delivery](#delivery).

## Integrate

| | |
|---|---|
| [Payment methods by platform](payment-methods-matrix.md) | What this SDK supports, method by method, versus web and Android. |
| **Getting started** *(not written — SDK-12266)* | Install via SPM, create the checkout, render a method, pay, confirm. |
| Recipes *(not written)* | One task per section: each payment method, gift cards, saved cards, hooks, theme, errors, session refresh, BNPL. |
| API reference *(not written)* | Generated DocC, shipped with each release. |
| Per-plugin notes *(not written)* | Card, redirection, Apple Pay, PayPal, Klarna — Android ships six such pages. |
| Monitoring and analytics *(not written)* | What the SDK reports to Purse and what never leaves the device. The behaviour shipped with SDK-12265; only the page is missing. |

## Work on the SDK

| | |
|---|---|
| [Architecture](architecture/headless-checkout.md) | Layers, the Purse-payment flow, how this maps to Android. |
| [Web ↔ Android ↔ iOS map](web-android-ios-map.md) | The file behind each file, and every deliberate divergence. |
| [AGENTS.md](../AGENTS.md) | Invariants that must not be broken, and why each exists. |

## Delivery

| Ticket | Scope | State |
|---|---|---|
| SDK-12260 | Core, payment model, splitter, reactive state, partner-ui contract, submit, card payment | done |
| SDK-12261 | payment method catalogue (Apple Pay, PayPal, Klarna, redirection, gift cards) | done |
| SDK-12262 | saved methods, BNPL, theme, hooks | done |
| SDK-12263 | suspensions, error taxonomy, lifecycle | done; its AC says 14 suspension codes and needs amending to 11 |
| SDK-12264 | packaging and delivery | partial — privacy manifest done; XCFramework signing and SwiftLint/SwiftFormat are not |
| SDK-12265 | observability | done |
| SDK-12266 | documentation | the *not written* rows above |

No "you are here" marker: it rotted the moment a PR landed without someone moving it, and the state
column above cannot rot the same way.

Requirements: iOS 16, Swift 6.
