// Web: packages/headless-checkout/src/utils/error/error.ts (thrown checkout errors)
// Same: same codes.
// Differs: an enum rather than a sealed class hierarchy.

import Foundation

/// Errors raised by the checkout itself, as opposed to session decoding (``PurseSessionError``) or
/// Payment API transport (``PaymentAPIError``). All three share the ``PurseError`` root.
public enum PurseCheckoutError: PurseError {
    /// The split does not cover the amount, so there is nothing valid to submit.
    case paymentNotFulfilled(String)
    /// Selecting a method or token whose disabled state is set.
    case methodDisabled(itemId: String, disabled: DisabledState)
    /// A refused `takeSplit` — see the associated ``PurseErrorCode``.
    case invalidTake(String, PurseErrorCode)
    /// The new session handed to `setSession` is already expired.
    case sessionExpired(sessionId: String)

    public var code: PurseErrorCode {
        switch self {
        case .paymentNotFulfilled: .paymentNotFulfilledOnSubmit
        case .methodDisabled: .methodDisabled
        case let .invalidTake(_, code): code
        case .sessionExpired: .expiredSession
        }
    }

    public var message: String {
        switch self {
        case let .paymentNotFulfilled(detail):
            detail
        case let .methodDisabled(itemId, disabled):
            "\(itemId) is disabled: \(disabled.message)"
        case let .invalidTake(detail, _):
            detail
        case let .sessionExpired(sessionId):
            "session \(sessionId) is already expired"
        }
    }
}
