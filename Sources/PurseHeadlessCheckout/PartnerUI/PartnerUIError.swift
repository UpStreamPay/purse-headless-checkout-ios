// Web: packages/partner-ui error surface
// Same: a partner's native step failing is its own error type, distinct from an API failure.
// Differs: no `PluginEvent`/`UnifiedEvent` peer — see the note below.

import Foundation

/// A partner's native step failed — its SDK returned an error, a card tokenization was refused, or
/// a coordinator was driven before it was prepared.
public struct PartnerUIError: PurseError {
    public let message: String
    public let underlying: (any Error)?

    public var code: PurseErrorCode { .partnerUIError }

    public init(_ message: String, underlying: (any Error)? = nil) {
        self.message = message
        self.underlying = underlying
    }
}

// MARK: - Not ported: the plugin event stream
//
// Android has `PluginEvent` (web's `UnifiedEvent`) plus a `pluginEvents` SharedFlow: a coordinator
// reports `Ready` / `InitFailed` / `PartnerError` / `EndOfSession` back to the checkout, which
// clears a recoverable disabled state, deactivates the method, or terminates the session, and
// re-exposes every event to the merchant's UI. It also emits `PARTNER_UI_EVENT` to monitoring.
//
// iOS has none of that wiring. A `PluginEvent` enum and a `PaymentOutcome` enum did exist here as
// public types with **no producer and no consumer anywhere in the SDK** — a merchant could never
// have received one. They are removed rather than left in the published API: shipping a public type
// that promises behaviour nothing implements is exactly the scaffolding AGENTS.md forbids, and
// removing it later would be a breaking change.
//
// Building it for real means: a `dispatchEvent` on `PartnerUIContext`, the checkout-side reactions
// above, and an `AsyncStream` on the checkout (Android's SharedFlow). That is a feature, not a fix
// — see docs/web-android-ios-map.md.
