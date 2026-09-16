// Web: packages/headless-checkout/src/utils/error/error-codes.ts
// Same: same codes.
// Differs: SUBMIT_BLOCKED, CHECKOUT_TORN_DOWN and PARTNER_UI_ERROR are thrown here where web only logs (or has no lifecycle end) — carried over from the Android port.

import Foundation

/// Machine-readable error codes for the SDK's error surface — the Swift analog of web's
/// `PurseHeadlessCheckoutErrorCodes`.
public enum PurseErrorCode: String, Sendable, CaseIterable {
    // Session
    case expiredSession = "EXPIRED_SESSION"
    case sessionMalformed = "SESSION_MALFORMED"
    /// Submitting a session that is being submitted, already submitted, or terminated.
    case submitBlocked = "SUBMIT_BLOCKED"
    /// Any operation after `teardown()`.
    case checkoutTornDown = "CHECKOUT_TORN_DOWN"

    // Payment process
    case validateFailed = "VALIDATE_FAILED"
    case postValidateFailed = "POST_VALIDATE_FAILED"
    case paymentNotFulfilledOnSubmit = "PAYMENT_NOT_FULFILLED_ON_SUBMIT"
    case elementNotFulfilled = "ELEMENT_NOT_FULFILLED"
    case uiValidationFailedError = "UI_VALIDATION_FAILED_ERROR"
    case onBeforeValidateHookFailed = "ON_BEFORE_VALIDATE_HOOK_FAILED"
    case methodNotImplemented = "METHOD_NOT_IMPLEMENTED"
    /// Selecting a method (or saved token) whose `disabled` state is set.
    case methodDisabled = "METHOD_DISABLED"
    /// A partner's native step failed: its SDK returned an error, a tokenization was refused, or a
    /// coordinator was driven before `prepare`.
    case partnerUIError = "PARTNER_UI_ERROR"

    // Secondary methods
    case failedToInitSecondaryToken = "FAILED_TO_INIT_SECONDARY_TOKEN"
    case secondaryMethodRequiredCVV = "SECONDARY_METHOD_REQUIRED_CVV"
    case secondaryMethodWrongPANFormat = "SECONDARY_METHOD_WRONG_PAN_FORMAT"
    case secondaryMethodWrongCVVFormat = "SECONDARY_METHOD_WRONG_CVV_FORMAT"
    case secondaryTokenEmptyBalance = "SECONDARY_TOKEN_EMPTY_BALANCE"
    case invalidTakeAmount = "INVALID_TAKE_AMOUNT"
    case maxAmountReached = "MAX_AMOUNT_REACHED"
    case usageLimitError = "USAGE_LIMIT_ERROR"

    // Wallet / tokens
    case missingWalletSession = "MISSING_WALLET_SESSION"
    case missingToken = "MISSING_TOKEN"
    case setWalletSessionFailed = "SET_WALLET_SESSION_FAILED"
    case invalidTokenName = "INVALID_TOKEN_NAME"
    case tokenNameExists = "TOKEN_NAME_EXISTS"
    case tokenNotRegisterable = "TOKEN_NOT_REGISTERABLE"
    case methodNotRegisterable = "METHOD_NOT_REGISTERABLE"
    case failedToDeleteAllTokens = "FAILED_TO_DELETE_ALL_TOKENS"

    // Loan simulation
    case methodIsNotSimulable = "METHOD_IS_NOT_SIMULABLE"
    case invalidLoanSimulation = "INVALID_LOAN_SIMULATION"

    // Transport / other
    case apiError = "API_ERROR"
    case unknownError = "UNKNOWN_ERROR"

    /// The shared error-codes documentation anchor for this code — web's `getErrorDocLink`.
    public var documentationLink: String {
        "https://docs.purse.tech/docs/integrate/purse-checkout/headless-checkout/"
            + "error-handling/error-codes#\(rawValue.lowercased())"
    }
}
