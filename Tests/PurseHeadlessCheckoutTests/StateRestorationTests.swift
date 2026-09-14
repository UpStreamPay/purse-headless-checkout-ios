import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// `saveState()` / `CheckoutSavedState.toJSON()`/`fromJSON(_:)` / `restore(_:)` — picking a payment
/// up after the process was killed. None of these tests touch the network (no saved tokens, no
/// wallet session in the fixtures), so this suite claims no `PurseEnvironment` tier.
@MainActor
struct StateRestorationTests {

    private func primaryMethod(_ checkout: PurseHeadlessCheckout) throws -> PrimaryMethod {
        try #require(checkout.paymentMethods.compactMap { item -> PrimaryMethod? in
            if case let .primaryMethod(method) = item { return method }
            return nil
        }.first)
    }

    // MARK: JSON round trip

    private func registerableProtocols() -> [String: Any] {
        TestSessions.cardProtocol(settings: ["save_token_mode": "PREFER"])
    }

    @Test func toJSONAndFromJSONRoundTripEverything() throws {
        let checkout = try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(
                paymentSession: TestSessions.paymentSession(amount: 100, protocols: registerableProtocols())
            ),
            urlSession: StubURLProtocol.session()
        )
        let method = try primaryMethod(checkout)
        try checkout.setPrimary(method)
        try checkout.register(method, name: "My card")

        let saved = try checkout.saveState()
        let restored = try CheckoutSavedState.fromJSON(saved.toJSON())

        #expect(restored.primaryId == method.id)
        #expect(restored.registrationByMethod[method.id]?.name == "My card")
        #expect(restored.submitted == false)
    }

    @Test func fromJSONRejectsGarbage() {
        #expect(throws: PurseSessionError.self) { try CheckoutSavedState.fromJSON("not json") }
        #expect(throws: PurseSessionError.self) { try CheckoutSavedState.fromJSON(#"{"version":1}"#) }
        #expect(throws: PurseSessionError.self) { try CheckoutSavedState.fromJSON(#"{"version":99,"widgetData":"x"}"#) }
    }

    // MARK: restore()

    @Test func restoreRebuildsThePrimarySelection() throws {
        let checkout = try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(paymentSession: TestSessions.paymentSession(amount: 100)),
            urlSession: StubURLProtocol.session()
        )
        let method = try primaryMethod(checkout)
        try checkout.setPrimary(method)

        let restored = try PurseHeadlessCheckout.restore(checkout.saveState(), urlSession: StubURLProtocol.session())
        #expect(restored.amountSplit.contains { $0.source.id == method.id })
    }

    @Test func restoreRebuildsTheRegistrationDecision() throws {
        let checkout = try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(
                paymentSession: TestSessions.paymentSession(amount: 100, protocols: registerableProtocols())
            ),
            urlSession: StubURLProtocol.session()
        )
        let method = try primaryMethod(checkout)
        try checkout.setPrimary(method)
        try checkout.register(method, registered: true, name: "Saved")

        let restored = try PurseHeadlessCheckout.restore(checkout.saveState(), urlSession: StubURLProtocol.session())
        let restoredMethod = try primaryMethod(restored)
        #expect(restored.registrationOf(restoredMethod).name == "Saved")
    }

    /// A submit that already left the device before the process died must never be repeated — the
    /// restored session reports as spent, and a second submit is refused.
    @Test func restoreMarksTheSessionSubmittedWhenOneHadAlreadyLeft() async throws {
        let checkout = try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(paymentSession: TestSessions.paymentSession(amount: 100)),
            urlSession: StubURLProtocol.session()
        )
        let saved = CheckoutSavedState(
            widgetData: TestSessions.widgetData(paymentSession: TestSessions.paymentSession(amount: 100)),
            lockedEnvironment: nil, disabledMethods: [], instanceId: checkout.instanceId,
            primaryId: nil, secondaries: [], registrationByMethod: [:], registrationBySecondaryToken: [:],
            collectedByItem: [:], submitted: true, savedAt: Date()
        )
        let restored = try PurseHeadlessCheckout.restore(saved, urlSession: StubURLProtocol.session())
        #expect(restored.sessionState == .submitted)
        await #expect(throws: PurseCheckoutError.self) { try await restored.submitPayment() }
    }

    /// A primary the restored session no longer offers (or now disables) is skipped, not crashed on.
    @Test func restoreSkipsAPrimaryThatIsNoLongerSelectable() throws {
        let saved = CheckoutSavedState(
            widgetData: TestSessions.widgetData(paymentSession: TestSessions.paymentSession(amount: 100)),
            lockedEnvironment: nil, disabledMethods: [], instanceId: UUID().uuidString,
            primaryId: "does-not-exist", secondaries: [], registrationByMethod: [:], registrationBySecondaryToken: [:],
            collectedByItem: [:], submitted: false, savedAt: Date()
        )
        let restored = try PurseHeadlessCheckout.restore(saved, urlSession: StubURLProtocol.session())
        #expect(restored.amountSplit.isEmpty)
    }

    /// A saved secondary slice the new session cannot honour is dropped rather than failing the
    /// whole restore.
    @Test func restoreDropsASecondarySliceThatNoLongerFits() throws {
        let saved = CheckoutSavedState(
            widgetData: TestSessions.widgetData(paymentSession: TestSessions.paymentSession(amount: 100)),
            lockedEnvironment: nil, disabledMethods: [], instanceId: UUID().uuidString,
            primaryId: nil,
            secondaries: [(
                SecondaryToken(
                    id: "illicado-giftcard-1", partner: .illicado, method: .giftCard,
                    pan: "9250004781234567890", cvv: "123", name: "Gift card", balance: 50
                ),
                200 // more than the order amount — cannot be honoured.
            )],
            registrationByMethod: [:], registrationBySecondaryToken: [:], collectedByItem: [:],
            submitted: false, savedAt: Date()
        )
        let restored = try PurseHeadlessCheckout.restore(saved, urlSession: StubURLProtocol.session())
        #expect(restored.amountSplit.isEmpty)
    }
}
