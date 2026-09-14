// Web: packages/headless-checkout/src/monitoring/monitoringConfigs.ts
// Same: the same 45 codes and levels (Android's superset — see the map doc).
// Differs: `methodDisabled` fires from `refresh()`'s before/after diff, the same idea Android's `reportDisabledTransitions` uses.

import Foundation

/// Every analytics event the checkout can emit — parity with web's
/// `PurseHeadlessCheckoutEventPayload` keys and Android's `CheckoutEventCode`.
public enum CheckoutEventCode: String, Sendable, CaseIterable {
    case clearPrimarySplit = "HEADLESS_CHECKOUT_CLEAR_PRIMARY_SPLIT"
    case clientHookError = "HEADLESS_CHECKOUT_CLIENT_HOOK_ERROR"
    case create = "HEADLESS_CHECKOUT_CREATE"
    case deleteAllTokens = "HEADLESS_CHECKOUT_DELETE_ALL_TOKENS"
    case expiredSession = "HEADLESS_CHECKOUT_EXPIRED_SESSION"
    case methodGetPaymentElement = "HEADLESS_CHECKOUT_METHOD_GET_PAYMENT_ELEMENT"
    case methodGetHostedFields = "HEADLESS_CHECKOUT_METHOD_GET_HOSTED_FIELDS"
    /// Every transition of a method into a `DisabledState` (a platform suspension, an amount rule,
    /// a partner failure) as one event with the state's code.
    case methodDisabled = "HEADLESS_CHECKOUT_METHOD_DISABLED"
    case methodGetSecondaryToken = "HEADLESS_CHECKOUT_METHOD_GET_SECONDARY_TOKEN"
    case methodLoanSim = "HEADLESS_CHECKOUT_METHOD_LOAN_SIM"
    case methodRegister = "HEADLESS_CHECKOUT_METHOD_REGISTER"
    case methodSetPrimary = "HEADLESS_CHECKOUT_METHOD_SET_PRIMARY"
    case otherError = "HEADLESS_CHECKOUT_OTHER_ERROR"
    case pageUnload = "HEADLESS_CHECKOUT_PAGE_UNLOAD"
    case partnerUIEvent = "HEADLESS_CHECKOUT_PARTNER_UI_EVENT"
    case partnerAPICallStart = "HEADLESS_CHECKOUT_PARTNER_API_CALL_START"
    case partnerAPICallEnd = "HEADLESS_CHECKOUT_PARTNER_API_CALL_END"
    case paymentElementAppendTo = "HEADLESS_CHECKOUT_PAYMENT_ELEMENT_APPEND_TO"
    case paymentElementRemove = "HEADLESS_CHECKOUT_PAYMENT_ELEMENT_REMOVE"
    case paymentElementSetOptions = "HEADLESS_CHECKOUT_PAYMENT_ELEMENT_SET_OPTIONS"
    case paymentElementValidateUI = "HEADLESS_CHECKOUT_PAYMENT_ELEMENT_VALIDATE_UI"
    case paymentElementListenerAttached = "HEADLESS_CHECKOUT_PAYMENT_ELEMENT_LISTENER_ATTACHED"
    case validationStarted = "HEADLESS_CHECKOUT_VALIDATION_STARTED"
    case preValidationFailed = "HEADLESS_CHECKOUT_PRE_VALIDATION_FAILED"
    case validationSuccess = "HEADLESS_CHECKOUT_VALIDATION_SUCCESS"
    case validationFailed = "HEADLESS_CHECKOUT_VALIDATION_FAILED"
    case paymentError = "HEADLESS_CHECKOUT_PAYMENT_ERROR"
    case paymentFulfilled = "HEADLESS_CHECKOUT_PAYMENT_FULFILLED"
    case primaryTokenGetPaymentElement = "HEADLESS_CHECKOUT_PRIMARY_TOKEN_GET_PAYMENT_ELEMENT"
    case primaryTokenSetAsPrimary = "HEADLESS_CHECKOUT_PRIMARY_TOKEN_SET_AS_PRIMARY"
    case reactiveValueSubscribe = "HEADLESS_CHECKOUT_REACTIVE_VALUE_SUBSCRIBE"
    case ready = "HEADLESS_CHECKOUT_READY"
    case secondaryTokenRegister = "HEADLESS_CHECKOUT_SECONDARY_TOKEN_REGISTER"
    case secondaryTokenRemoveFromSplit = "HEADLESS_CHECKOUT_SECONDARY_TOKEN_REMOVE_FROM_SPLIT"
    case secondaryTokenTake = "HEADLESS_CHECKOUT_SECONDARY_TOKEN_TAKE"
    case setSession = "HEADLESS_CHECKOUT_SET_SESSION"
    case setWalletSession = "HEADLESS_CHECKOUT_SET_WALLET_SESSION"
    case setWalletSessionFailed = "HEADLESS_CHECKOUT_SET_WALLET_SESSION_FAILED"
    case submitPayment = "HEADLESS_CHECKOUT_SUBMIT_PAYMENT"
    case submitBlocked = "HEADLESS_CHECKOUT_SUBMIT_BLOCKED"
    case tokenDelete = "HEADLESS_CHECKOUT_TOKEN_DELETE"
    case tokenEdit = "HEADLESS_CHECKOUT_TOKEN_EDIT"
    case tokenSetFavorite = "HEADLESS_CHECKOUT_TOKEN_SET_FAVORITE"
    case uncaughtError = "HEADLESS_CHECKOUT_UNCAUGHT_ERROR"
    case onBeforeValidateHookFailed = "HEADLESS_CHECKOUT_ON_BEFORE_VALIDATE_HOOK_FAILED"
}

/// Event severity — web common's `EventType`.
public enum EventLevel: String, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case error = "ERROR"
    case success = "SUCCESS"
    case warning = "WARNING"
    case performance = "PERFORMANCE"
    case ui = "UI"
    case network = "NETWORK"
}

/// One analytics event — code + level + free-form payload, stamped with the client's ISO datetime
/// at construction.
public struct CheckoutMonitoringEvent: Sendable {
    public let code: CheckoutEventCode
    public let type: EventLevel
    public let payload: JSONValue?
    public let dateString: String

    public init(
        code: CheckoutEventCode,
        type: EventLevel = .info,
        payload: JSONValue? = nil,
        dateString: String? = nil
    ) {
        self.code = code
        self.type = type
        self.payload = payload
        self.dateString = dateString ?? Self.now()
    }

    func toJSON() -> JSONValue {
        var object: [String: JSONValue] = [
            "code": .string(code.rawValue),
            "type": .string(type.rawValue),
            "dateString": .string(dateString)
        ]
        if let payload { object["payload"] = payload }
        return .object(object)
    }

    private static func now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
