// Web: packages/headless-checkout mops recompute on `primaryReach`
// Same: min/max amount and information-request rules.
// Differs: nothing.

import Foundation

/// The amount-driven subset of web's `updateMopDisabledState` plus the build-time rules of
/// `buildDisabledWritable`: given how much a primary still has to pay (`primaryReach` — the session
/// amount minus what applied secondaries cover), decide whether each method is currently
public enum MethodAvailability {

    /// The permanent, build-time disabled state for one method, or `nil`: - `configurations.stable
    /// == false` → ``DisabledState/methodUnstable`` (a platform suspension); - `payment_min_amount`
    /// above the full order amount →
    public static func buildTimeDisabled(
        for configuration: MethodConfiguration,
        orderAmount: Decimal
    ) -> DisabledState? {
        if !configuration.stable { return .methodUnstable }

        if let minAmount = configuration.settings.paymentMinAmount, orderAmount > 0, minAmount > orderAmount {
            return .amountConditionUnreachable(
                minAmount: minAmount,
                maxAmount: configuration.settings.paymentMaxAmount,
                orderAmount: orderAmount
            )
        }
        return nil
    }

    /// The amount-driven disabled reason for one method against `primaryReach`; `nil` when
    /// selectable. An information-request session never disables on amount.
    public static func disabled(
        for configuration: MethodConfiguration,
        isInformationRequest: Bool,
        primaryReach: Decimal,
        isInSplit: Bool = false
    ) -> DisabledState? {
        if isInformationRequest { return nil }

        let minAmount = configuration.settings.paymentMinAmount
        let maxAmount = configuration.settings.paymentMaxAmount

        if !isInSplit, primaryReach == 0 {
            return .paymentFulfilled
        }
        if !isInSplit, let minAmount, primaryReach < minAmount {
            return .minAmountNotMet(minAmount: minAmount, restToPay: primaryReach)
        }
        // A secondary is never disabled for exceeding max — a gift card can legitimately hold more
        // balance than the amount owed; it just cannot draw down more than what is left.
        if let maxAmount, primaryReach > maxAmount, !configuration.isSecondary {
            return .maxAmountExceeded(maxAmount: maxAmount, restToPay: primaryReach)
        }
        return nil
    }

    /// Recompute every item's disabled state against a new `primaryReach`, returning a fresh list.
    /// Items whose current state is not ``DisabledState/isRecomputable`` are kept untouched — a
    /// suspension or a partner failure is final for the session.
    public static func recompute(
        _ methods: [PaymentItem],
        isInformationRequest: Bool,
        primaryReach: Decimal,
        splitSources: [any SplitSource] = []
    ) -> [PaymentItem] {
        methods.map { item in
            if let current = item.disabled, !current.isRecomputable {
                return item
            }
            let isInSplit = splitSources.contains {
                $0.partner == item.partner && $0.method == item.method
            }
            return item.withDisabled(
                disabled(
                    for: item.configuration,
                    isInformationRequest: isInformationRequest,
                    primaryReach: primaryReach,
                    isInSplit: isInSplit
                )
            )
        }
    }
}
