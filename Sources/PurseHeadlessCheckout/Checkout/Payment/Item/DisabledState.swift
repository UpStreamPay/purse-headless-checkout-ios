// Web: packages/headless-checkout/src/session/payment/mops/disabled.ts
// Same: same codes and messages, recoverable / filtered / requiresUIClear sets.
// Differs: SUBMITTING is set on every method during a submit (web declares it but never sets it).

import Foundation

/// Why a ``PaymentItem`` currently cannot be selected, even though the session offers it. Every
/// state carries web's displayable ``message``; the amount-driven ones also carry their context
/// (minimum, maximum, amount still owed).
public enum DisabledState: Sendable, Equatable {

    /// The platform suspended the method: `configurations.stable == false`. Permanent for the
    /// session, and filtered from the public list.
    case methodUnstable

    /// `payment_min_amount` exceeds the full order amount, so no split could ever enable the
    /// method. Computed once at session build, and filtered from the list.
    case amountConditionUnreachable(minAmount: Decimal, maxAmount: Decimal?, orderAmount: Decimal)

    /// The remaining amount owed by a primary is already zero.
    case paymentFulfilled

    case minAmountNotMet(minAmount: Decimal, restToPay: Decimal)

    /// Never applies to secondary methods — a gift card can hold more than the amount owed.
    case maxAmountExceeded(maxAmount: Decimal, restToPay: Decimal?)

    /// The resolved plugin rejected the current client/session in its eligibility pre-check.
    case pluginIncompatible

    /// A secondary's `/init` failed terminally for this session.
    case tokenInitFailed

    /// A partner plugin reported an unrecoverable failure while mounted.
    case partnerUIFatalError(reason: String?)

    /// A partner plugin reported a failure it expects to come back from without a restart.
    case partnerUIRecoverableError(reason: String?)

    /// The plugin failed before it could mount any UI at all.
    case fatalErrorBeforeRender(reason: String?)

    /// A payment is being submitted — every method is locked until the submit returns.
    case submitting

    // MARK: Code

    public enum Code: String, Sendable, CaseIterable {
        case methodUnstable = "METHOD_UNSTABLE"
        case amountConditionUnreachable = "AMOUNT_CONDITION_UNREACHABLE"
        case paymentFulfilled = "PAYMENT_FULFILLED"
        case minAmountNotMet = "MIN_AMOUNT_NOT_MET"
        case maxAmountExceeded = "MAX_AMOUNT_EXCEEDED"
        case pluginIncompatible = "PLUGIN_INCOMPATIBLE"
        case tokenInitFailed = "TOKEN_INIT_FAILED"
        case partnerUIFatalError = "PARTNER_UI_FATAL_ERROR"
        case partnerUIRecoverableError = "PARTNER_UI_RECOVERABLE_ERROR"
        case fatalErrorBeforeRender = "FATAL_ERROR_BEFORE_RENDER"
        case submitting = "SUBMITTING"
    }

    public var code: Code {
        switch self {
        case .methodUnstable: .methodUnstable
        case .amountConditionUnreachable: .amountConditionUnreachable
        case .paymentFulfilled: .paymentFulfilled
        case .minAmountNotMet: .minAmountNotMet
        case .maxAmountExceeded: .maxAmountExceeded
        case .pluginIncompatible: .pluginIncompatible
        case .tokenInitFailed: .tokenInitFailed
        case .partnerUIFatalError: .partnerUIFatalError
        case .partnerUIRecoverableError: .partnerUIRecoverableError
        case .fatalErrorBeforeRender: .fatalErrorBeforeRender
        case .submitting: .submitting
        }
    }

    /// A human-readable explanation a merchant can show. Amount-bearing messages quote figures,
    /// which is why **only the code is ever sent to monitoring** — see the privacy invariant in
    /// AGENTS.md.
    public var message: String {
        switch self {
        case .methodUnstable:
            "This payment method is currently unstable and cannot be used."
        case .amountConditionUnreachable:
            "This payment cannot be used for this order"
        case .paymentFulfilled:
            "The payment amount has already been fulfilled."
        case let .minAmountNotMet(minAmount, restToPay):
            "The minimum amount for this payment method is \(minAmount.plainString). "
                + "Amount is currently \(restToPay.plainString)."
        case let .maxAmountExceeded(maxAmount, restToPay):
            "The maximum amount for this payment method is \(maxAmount.plainString)."
                + (restToPay.map { " Amount is currently \($0.plainString)." } ?? "")
        case .pluginIncompatible:
            "This payment method is not compatible with the current client."
        case .tokenInitFailed:
            "Failed to initialize the secondary payment token."
        case .partnerUIFatalError:
            "An unexpected error occurred in the payment form. The payment method has been deactivated."
        case .partnerUIRecoverableError:
            "This payment method is temporarily unavailable."
        case .fatalErrorBeforeRender:
            "This payment method is not eligible for this order."
        case .submitting:
            "A payment is being submitted."
        }
    }

    // MARK: The five behaviours

    public var isFiltered: Bool { Self.filteredCodes.contains(code) }
    public var isTechnicallyDisabled: Bool { Self.technicallyDisabledCodes.contains(code) }
    public var requiresUIClear: Bool { Self.shouldClearUICodes.contains(code) }
    public var isRecoverable: Bool { Self.recoverableCodes.contains(code) }
    public var isRecomputable: Bool { Self.recomputableCodes.contains(code) }

    /// Web `FilteredDisabledStateCodes` — the item disappears from the public method list.
    public static let filteredCodes: Set<Code> = [
        .methodUnstable, .amountConditionUnreachable, .fatalErrorBeforeRender, .pluginIncompatible,
    ]

    /// Web `TechnicallyDisabledStateCodes`, minus the DOM-only codes.
    public static let technicallyDisabledCodes: Set<Code> = [.tokenInitFailed, .partnerUIFatalError]

    /// Web `ShouldClearUIDisabledStatesCodes`.
    public static let shouldClearUICodes: Set<Code> = technicallyDisabledCodes
        .union([.minAmountNotMet, .paymentFulfilled, .maxAmountExceeded])

    /// Web `RecoverableDisabledStateCodes`.
    public static let recoverableCodes: Set<Code> = [.partnerUIRecoverableError]

    /// Web `RecomputableDisabledStateCodes` — the only states a change in the amount to pay
    /// re-evaluates; everything else is final for the session.
    public static let recomputableCodes: Set<Code> = recoverableCodes
        .union([.minAmountNotMet, .paymentFulfilled, .maxAmountExceeded])
}

extension Decimal {
    /// A plain, non-scientific rendering — Kotlin's `BigDecimal.toPlainString()`.
    var plainString: String { NSDecimalNumber(decimal: self).stringValue }
}
