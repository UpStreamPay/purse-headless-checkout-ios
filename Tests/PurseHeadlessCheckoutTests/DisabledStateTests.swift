import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// The suspension model. Ported from Android's `DisabledState.kt` / `MethodAvailabilityTest.kt`.
struct DisabledStateTests {

    /// The code set is shared with Android. A code added on one platform and not the other is
    /// exactly the drift this pins — and note SDK-12263's AC says fourteen, which is web's count,
    /// not Android's. The AC needs amending; the code here is deliberate.
    @Test func theCodeSetMatchesAndroid() {
        let android: Set<String> = [
            "METHOD_UNSTABLE", "AMOUNT_CONDITION_UNREACHABLE", "PAYMENT_FULFILLED",
            "MIN_AMOUNT_NOT_MET", "MAX_AMOUNT_EXCEEDED", "PLUGIN_INCOMPATIBLE", "TOKEN_INIT_FAILED",
            "PARTNER_UI_FATAL_ERROR", "PARTNER_UI_RECOVERABLE_ERROR", "FATAL_ERROR_BEFORE_RENDER",
            "SUBMITTING",
        ]
        #expect(Set(DisabledState.Code.allCases.map(\.rawValue)) == android)
        #expect(DisabledState.Code.allCases.count == 11)
    }

    /// The five behaviours, pinned by membership. Web's lists, minus the DOM-only codes.
    @Test func theFiveBehaviourSetsMatchWeb() {
        #expect(DisabledState.filteredCodes == [
            .methodUnstable, .amountConditionUnreachable, .fatalErrorBeforeRender, .pluginIncompatible,
        ])
        #expect(DisabledState.technicallyDisabledCodes == [.tokenInitFailed, .partnerUIFatalError])
        #expect(DisabledState.shouldClearUICodes == [
            .tokenInitFailed, .partnerUIFatalError, .minAmountNotMet, .paymentFulfilled, .maxAmountExceeded,
        ])
        #expect(DisabledState.recoverableCodes == [.partnerUIRecoverableError])
        #expect(DisabledState.recomputableCodes == [
            .partnerUIRecoverableError, .minAmountNotMet, .paymentFulfilled, .maxAmountExceeded,
        ])
    }

    /// A recoverable partner failure keeps its UI mounted — it is deliberately absent from the
    /// technically-disabled and clear-UI sets, so the shopper can use it again when it comes back.
    @Test func aRecoverablePartnerErrorKeepsItsUIMounted() {
        let state = DisabledState.partnerUIRecoverableError(reason: "timeout")
        #expect(state.isRecoverable)
        #expect(state.isRecomputable)
        #expect(!state.isTechnicallyDisabled)
        #expect(!state.requiresUIClear)
        #expect(!state.isFiltered)
    }

    /// A fatal partner failure is final for the session — an amount change must not revive it.
    @Test func aFatalPartnerErrorIsFinal() {
        let state = DisabledState.partnerUIFatalError(reason: "boom")
        #expect(state.isTechnicallyDisabled)
        #expect(state.requiresUIClear)
        #expect(!state.isRecomputable)
    }

    @Test func everyStateCarriesAMessage() {
        let states: [DisabledState] = [
            .methodUnstable,
            .amountConditionUnreachable(minAmount: 50, maxAmount: nil, orderAmount: 10),
            .paymentFulfilled,
            .minAmountNotMet(minAmount: 20, restToPay: 5),
            .maxAmountExceeded(maxAmount: 100, restToPay: 200),
            .pluginIncompatible,
            .tokenInitFailed,
            .partnerUIFatalError(reason: nil),
            .partnerUIRecoverableError(reason: nil),
            .fatalErrorBeforeRender(reason: nil),
            .submitting,
        ]
        #expect(states.count == DisabledState.Code.allCases.count)
        #expect(states.allSatisfy { !$0.message.isEmpty })
    }

    /// Amount-bearing messages quote figures — which is exactly why only the *code* is ever sent to
    /// monitoring. See the privacy invariant in AGENTS.md.
    @Test func amountMessagesQuoteTheirFigures() {
        let state = DisabledState.minAmountNotMet(minAmount: 20, restToPay: 5)
        #expect(state.message.contains("20"))
        #expect(state.message.contains("5"))
    }
}

struct MethodAvailabilityTests {

    private func configuration(
        stable: Bool = true,
        min: Decimal? = nil,
        max: Decimal? = nil,
        secondary: Bool = false
    ) -> MethodConfiguration {
        MethodConfiguration(
            stable: stable,
            template: nil,
            labels: secondary ? ["secondary"] : [],
            position: nil,
            vault: nil,
            settings: MethodSettings(
                registrationMode: .unknown,
                saveToken: nil,
                saveTokenMode: nil,
                directDebit: false,
                paymentMinAmount: min,
                paymentMaxAmount: max,
                usagePerSessionLimit: nil,
                integrationMode: nil
            )
        )
    }

    // MARK: Build time

    @Test func anUnstableMethodIsSuspended() {
        #expect(MethodAvailability.buildTimeDisabled(for: configuration(stable: false), orderAmount: 100) == .methodUnstable)
    }

    @Test func aMinimumAboveTheOrderIsUnreachable() {
        let state = MethodAvailability.buildTimeDisabled(for: configuration(min: 50), orderAmount: 10)
        #expect(state?.code == .amountConditionUnreachable)
    }

    @Test func aReachableMinimumIsNotABuildTimeProblem() {
        #expect(MethodAvailability.buildTimeDisabled(for: configuration(min: 50), orderAmount: 100) == nil)
    }

    /// A zero order amount skips the minimum rule, which also exempts information requests.
    @Test func aZeroOrderAmountSkipsTheMinimumRule() {
        #expect(MethodAvailability.buildTimeDisabled(for: configuration(min: 50), orderAmount: 0) == nil)
    }

    // MARK: Amount driven

    @Test func nothingIsDisabledOnAmountInAnInformationRequest() {
        let state = MethodAvailability.disabled(
            for: configuration(min: 50, max: 60), isInformationRequest: true, primaryReach: 0
        )
        #expect(state == nil)
    }

    @Test func aCoveredAmountFulfilsEveryMethodNotInTheSplit() {
        #expect(MethodAvailability.disabled(for: configuration(), isInformationRequest: false, primaryReach: 0)
            == .paymentFulfilled)
    }

    @Test func belowTheMinimumIsRefused() {
        let state = MethodAvailability.disabled(for: configuration(min: 20), isInformationRequest: false, primaryReach: 5)
        #expect(state?.code == .minAmountNotMet)
    }

    @Test func aboveTheMaximumIsRefused() {
        let state = MethodAvailability.disabled(for: configuration(max: 100), isInformationRequest: false, primaryReach: 200)
        #expect(state?.code == .maxAmountExceeded)
    }

    /// A gift card may legitimately hold more balance than the amount owed — it simply draws less.
    @Test func secondariesAreNeverDisabledForExceedingTheMaximum() {
        let state = MethodAvailability.disabled(
            for: configuration(max: 100, secondary: true), isInformationRequest: false, primaryReach: 200
        )
        #expect(state == nil)
    }

    /// The in-split exemption covers fulfilled and below-minimum, but deliberately not maximum.
    @Test func beingInTheSplitExemptsFulfilledAndMinimumButNotMaximum() {
        #expect(MethodAvailability.disabled(
            for: configuration(), isInformationRequest: false, primaryReach: 0, isInSplit: true
        ) == nil)

        #expect(MethodAvailability.disabled(
            for: configuration(min: 20), isInformationRequest: false, primaryReach: 5, isInSplit: true
        ) == nil)

        #expect(MethodAvailability.disabled(
            for: configuration(max: 100), isInformationRequest: false, primaryReach: 200, isInSplit: true
        )?.code == .maxAmountExceeded)
    }

    // MARK: Recompute

    @Test func recomputeRevivesAnAmountDrivenState() {
        let item = PaymentItem.primaryMethod(PrimaryMethod(
            id: "purse-creditcard", partner: .purse, method: .creditCard,
            configuration: configuration(), disabled: .paymentFulfilled,
            integrationType: nil, supportedBrands: []
        ))

        let recomputed = MethodAvailability.recompute([item], isInformationRequest: false, primaryReach: 100)
        #expect(recomputed[0].disabled == nil)
    }

    /// A suspension or a partner failure survives every amount change.
    @Test(arguments: [DisabledState.methodUnstable, .partnerUIFatalError(reason: nil), .tokenInitFailed])
    func recomputeLeavesNonRecomputableStatesAlone(_ state: DisabledState) {
        let item = PaymentItem.primaryMethod(PrimaryMethod(
            id: "purse-creditcard", partner: .purse, method: .creditCard,
            configuration: configuration(), disabled: state,
            integrationType: nil, supportedBrands: []
        ))

        let recomputed = MethodAvailability.recompute([item], isInformationRequest: false, primaryReach: 100)
        #expect(recomputed[0].disabled == state)
    }
}
