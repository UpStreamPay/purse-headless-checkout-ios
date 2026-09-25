// Web: packages/partner-ui error surface
// Same: a partner's native step failing is its own error type, distinct from an API failure.
// Differs: none; the event a coordinator reports alongside it is `PluginEvent`.

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
