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
// clears a recoverable disabled state, deactivates the method, or terminates the session.
//
// iOS still has none of that wiring. `PluginEvent` and `PaymentOutcome` were both removed from here
// when they were public types with no producer and no consumer. `PaymentOutcome` is back, with a
// real producer — see Element/. `PluginEvent` is not: it needs a `dispatchEvent` on
// `PartnerUIContext`, the checkout-side reactions above, and an `AsyncStream` peer of Android's
// SharedFlow. A feature, not a fix — see docs/web-android-ios-map.md.
