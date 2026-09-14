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
    /// Submitting a session that is being submitted, already submitted, or terminated.
    case submitBlocked(state: SessionState)
    /// No plugin is registered for a method in the split — the partner product was never installed.
    case noPluginRegistered(itemId: String)
    /// No secondary configuration for an applied instrument.
    case noSecondaryConfig(itemId: String)
    /// An item in the split reports its own form incomplete.
    case itemNotFulfilled(itemId: String)
    /// The `/validate` call itself failed. Inspect ``underlying`` for a ``PaymentAPIError`` whose
    /// ``PaymentAPIError/outcomeUnknown`` means the payment may nonetheless exist.
    case validateFailed(String, (any Error)?)
    /// A merchant hook threw.
    case hookFailed(hook: String, underlying: any Error, code: PurseErrorCode)
    /// `/validate` **answered** — the payment exists, approved or declined — and a plugin's
    /// `postValidation` then threw.
    case postValidationFailed(result: ValidationResult, underlying: any Error)
    /// A secondary instrument could not be tokenized — a refused `/init`, or an empty balance.
    case secondaryTokenizationFailed(String, PurseErrorCode)
    /// The PAN or CVV typed for a secondary method does not match that issuer's format.
    case invalidSecondaryCard(String, PurseErrorCode)

    public var code: PurseErrorCode {
        switch self {
        case .paymentNotFulfilled: .paymentNotFulfilledOnSubmit
        case .methodDisabled: .methodDisabled
        case let .invalidTake(_, code): code
        case .sessionExpired: .expiredSession
        case .submitBlocked: .submitBlocked
        case .noPluginRegistered, .noSecondaryConfig: .methodNotImplemented
        case .itemNotFulfilled: .elementNotFulfilled
        case .validateFailed: .validateFailed
        case let .hookFailed(_, _, code): code
        case .postValidationFailed: .postValidateFailed
        case let .secondaryTokenizationFailed(_, code): code
        case let .invalidSecondaryCard(_, code): code
        }
    }

    public var underlying: (any Error)? {
        switch self {
        case let .validateFailed(_, underlying): underlying
        case let .hookFailed(_, underlying, _): underlying
        case let .postValidationFailed(_, underlying): underlying
        default: nil
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
        case let .submitBlocked(state):
            "a payment cannot be submitted while the session is \(state.rawValue)"
        case let .noPluginRegistered(itemId):
            "no plugin registered for \(itemId) — install the partner product that provides it"
        case let .noSecondaryConfig(itemId):
            "no secondary configuration for \(itemId)"
        case let .itemNotFulfilled(itemId):
            "\(itemId) has not reported its form complete"
        case let .validateFailed(detail, _):
            detail
        case let .hookFailed(hook, underlying, _):
            "the \(hook) hook failed: \(underlying)"
        case let .postValidationFailed(result, underlying):
            "validate answered \(result.globalStatus) but postValidation failed: \(underlying)"
        case let .secondaryTokenizationFailed(detail, _):
            detail
        case let .invalidSecondaryCard(detail, _):
            detail
        }
    }
}
