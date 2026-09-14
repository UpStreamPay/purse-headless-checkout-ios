// Web: packages/partner-ui/src/events.ts (`UnifiedEvent`)
// Same: the codes the checkout reacts to.
// Differs: no `fulfilled` (that travels through the host) and no `requestValidate`.

import Foundation

/// Lifecycle signals a coordinator sends back to the checkout. The checkout deactivates the method
/// on fatal events, clears a recoverable state on ``ready``, terminates the session on
/// ``endOfSession``, and re-exposes every event for the merchant's UI.
public enum PluginEvent: Sendable, Equatable {
    /// The plugin's client is up and usable — clears a recoverable disabled state.
    case ready
    /// The shopper is being sent to an external step (3-D Secure, PSP page).
    case redirect
    /// The plugin's `/init`/setup failed before any UI could work.
    case initFailed(message: String?)
    /// The vendor client failed unrecoverably.
    case clientError(message: String?)
    /// The partner reported an error; `recoverable` dims the method instead of disabling it.
    case partnerError(message: String?, recoverable: Bool)
    /// The shopper backed out of the partner flow.
    case cancelled
    /// The partner said the session is finished for good.
    case endOfSession

    /// A stable name — what monitoring carries as `code`.
    public var code: String {
        switch self {
        case .ready: "Ready"
        case .redirect: "Redirect"
        case .initFailed: "InitFailed"
        case .clientError: "ClientError"
        case .partnerError: "PartnerError"
        case .cancelled: "Cancelled"
        case .endOfSession: "EndOfSession"
        }
    }
}

/// How a payment attempt ended. The shopper may start another attempt after ``canceled`` or
/// ``failed``, never after ``completed`` — the session is spent.
public enum PaymentOutcome: Sendable {
    /// `/validate` answered without a redirect.
    case completed(ValidationResult)

    /// The shopper came back from a redirect (3-D Secure, a PSP page, PayPal's approval). This is
    /// **not** an outcome: the final redirect is built server-side and can land on a URL this
    /// client cannot read.
    case returnedFromRedirect

    /// The shopper backed out — a dismissed sheet, an abandoned approval, a closed redirect page.
    case canceled

    /// The attempt did not produce a payment. Nothing was charged, with one exception: a
    /// ``PaymentAPIError`` whose ``PaymentAPIError/outcomeUnknown`` is `true` means the request left
    /// the device unanswered — confirm against the session before showing a failure.
    case failed(any PurseError)

    public var isSuccess: Bool {
        if case let .completed(result) = self { return result.isSuccess }
        return false
    }
}

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

extension Error {
    /// This error as the SDK's typed error: itself when it already is one, else wrapped.
    var asPurseError: any PurseError {
        self as? any PurseError ?? PartnerUIError(localizedDescription, underlying: self)
    }
}
