// Web: packages/partner-ui/src/events.ts (`UnifiedEvent`)
// Same: Android's `PluginEvent` cases and `code` strings.
// Differs: re-exposed through a callback on the checkout, not a `SharedFlow`.

import Foundation

/// What a partner's native step reports back to the checkout. The checkout disables the method on
/// a fatal event, dims it on a recoverable one, clears that on ``ready``, and terminates the
/// session on ``endOfSession``.
public enum PluginEvent: Sendable, Equatable {
    /// The client is up again: clears a recoverable disabled state.
    case ready
    /// The shopper is being sent to an external step (3-D Secure, a PSP page).
    case redirect
    /// Setup (`/init`, the vendor client) failed before any UI worked.
    case initFailed(message: String?)
    /// The vendor client failed unrecoverably.
    case clientError(message: String?)
    /// `recoverable` dims the method instead of disabling it.
    case partnerError(message: String?, recoverable: Bool)
    /// The shopper backed out.
    case cancelled
    /// The partner says the session is over for good.
    case endOfSession

    /// Android's wire name, sent as `code` on `HEADLESS_CHECKOUT_PARTNER_UI_EVENT`.
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

    var message: String? {
        switch self {
        case let .initFailed(message), let .clientError(message), let .partnerError(message, _): message
        case .ready, .redirect, .cancelled, .endOfSession: nil
        }
    }
}

/// A ``PluginEvent`` and the item it came from.
public struct CheckoutPluginEvent: Sendable, Equatable {
    public let itemId: String
    public let event: PluginEvent
}
