# Documentation

A headless iOS SDK for Purse payments: it owns the payment engine (session, methods, split,
`/validate`) and lets you build the checkout UI. Same concepts as the web `usp-widget` headless SDK
and the Android SDK, in Swift.

> **Status: in development.** Only the Core layer has landed (session decode, Payment API client,
> environments, error taxonomy). The pages below marked *planned* describe work that is specified
> but not yet built — see [the PR sequence](#delivery).

## Integrate

| | |
|---|---|
| **Getting started** *(planned — SDK-12266)* | Install via SPM, create the checkout, render a method, pay, confirm. |
| Recipes *(planned)* | One task per section: each payment method, gift cards, saved cards, hooks, theme, errors, session refresh, BNPL. |
| API reference *(planned)* | Generated DocC, shipped with each release. |
| Payment methods by platform *(planned)* | What this SDK supports versus web and Android. |
| Monitoring and analytics *(planned — SDK-12265)* | What the SDK reports to Purse and what never leaves the device. |

## Work on the SDK

| | |
|---|---|
| [Architecture](architecture/headless-checkout.md) | Layers, the Purse-payment flow, how this maps to Android. |
| [Web ↔ Android ↔ iOS map](web-android-ios-map.md) | The file behind each file, and every deliberate divergence. |
| [AGENTS.md](../AGENTS.md) | Invariants that must not be broken, and why each exists. |

## Delivery

Nine stacked PRs across seven tickets:

| PR | Ticket | Scope |
|---|---|---|
| 1 | SDK-12260 | repo skeleton + Core |
| 2 | SDK-12260 | payment model, splitter, reactive state ← **you are here** |
| 3 | SDK-12260 | partner-ui contract + card payment end to end |
| 4 | SDK-12261 | payment method catalogue (Apple Pay, PayPal, Klarna, redirection, gift cards) |
| 5 | SDK-12262 | saved methods, BNPL, theme, hooks |
| 6 | SDK-12263 | suspensions, error taxonomy, lifecycle |
| 7 | SDK-12264 | packaging and delivery |
| 8 | SDK-12265 | observability |
| 9 | SDK-12266 | documentation |

Requirements: iOS 16, Swift 6.
