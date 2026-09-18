# Documentation

A headless iOS SDK for Purse payments: it owns the payment engine (session, methods, split,
`/validate`) and lets you build the checkout UI. Same concepts as the web `usp-widget` headless SDK
and the Android SDK, in Swift.

> **Status: in development.** The SDK is feature-complete for everything in scope: session, payment
> model, split, submit, the partner plugins, confirmation, observability and lifecycle. What is left
> is packaging — XCFramework signing, SwiftLint and SwiftFormat — and the pages below marked
> *not written*.

## Integrate

| | |
|---|---|
| [Payment methods by platform](payment-methods-matrix.md) | What this SDK supports, method by method, versus web and Android. |
| **Getting started** *(not written)* | Install via SPM, create the checkout, render a method, pay, confirm. |
| Recipes *(not written)* | One task per section: each payment method, gift cards, saved cards, hooks, theme, errors, session refresh, BNPL. |
| API reference *(not written)* | Generated DocC, shipped with each release. |
| Per-plugin notes *(not written)* | Card, redirection, Apple Pay, PayPal, Klarna — Android ships six such pages. |
| Monitoring and analytics *(not written)* | What the SDK reports to Purse and what never leaves the device. The behaviour ships today; only the page is missing. |

## Work on the SDK

| | |
|---|---|
| [Architecture](architecture/headless-checkout.md) | Layers, the Purse-payment flow, how this maps to Android. |
| [Web ↔ Android ↔ iOS map](web-android-ios-map.md) | The file behind each file, and every deliberate divergence. |
| [AGENTS.md](../AGENTS.md) | Invariants that must not be broken, and why each exists. |

Requirements: iOS 16, Swift 6.
