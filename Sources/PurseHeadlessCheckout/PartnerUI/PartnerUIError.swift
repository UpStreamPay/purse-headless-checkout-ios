// Web: packages/partner-ui error surface
// Same: a partner's native step failing is its own error type, distinct from an API failure.
// Differs: no `PluginEvent`/`UnifiedEvent` peer — see the note below.

import Foundation

/// A partner's native step failed: its SDK errored, a tokenization was refused, or a coordinator
/// was driven before it was prepared.
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
// Android's `PluginEvent` (web's `UnifiedEvent`) lets a coordinator report `Ready` / `InitFailed` /
// `PartnerError` / `EndOfSession` back to the checkout. iOS has no peer: it would need a
// `dispatchEvent` on `PartnerUIContext`, the checkout-side reactions, and an `AsyncStream`.
// A feature, not a fix — see docs/web-android-ios-map.md.
