import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// SDK-12561: web's PayPal bnpl eligibility probe. In redirection mode, an `/init` answering
/// `NOT_ELIGIBLE` withdraws the method before the shopper can pick it.
@MainActor
@Suite(.serialized)
struct PayPalBNPLEligibilityTests {

    /// A fictional root: all four tiers are claimed by other suites.
    private static let host = "api.bnpleligibility.example"

    private func widgetData(integrationMode: String) -> String {
        let protocols: [String: Any] = ["paypal": ["bnpl": ["configurations": [
            "stable": true, "labels": [],
            "settings": ["merchant_specifics": ["integration_mode": integrationMode]],
        ]]]]
        return TestSessions.widgetData(
            apiURL: "https://\(Self.host)/payment/v1",
            paymentSession: TestSessions.paymentSession(id: "bnpl-eligibility", amount: 100, protocols: protocols)
        )
    }

    private func makeCheckout(integrationMode: String) async throws -> PurseHeadlessCheckout {
        await InitGuard.shared.reset()
        let checkout = try PurseHeadlessCheckout(
            widgetData: widgetData(integrationMode: integrationMode),
            urlSession: StubURLProtocol.session()
        )
        for task in checkout.pendingEligibility { await task.value }
        return checkout
    }

    private func stubInit(_ body: String) {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/init", .ok(body), host: Self.host)
    }

    private func initCount() -> Int {
        StubURLProtocol.paths(host: Self.host).filter { $0.hasSuffix("/init") }.count
    }

    @Test func anIneligibleOrderWithdrawsTheMethod() async throws {
        stubInit(#"{"status":{"state":"SUCCESS"},"plugin_result":{"status":"NOT_ELIGIBLE"}}"#)
        let checkout = try await makeCheckout(integrationMode: "redirection")
        defer { Task { await InitGuard.shared.reset() } }

        #expect(initCount() == 1)
        #expect(checkout.paymentMethods.isEmpty)
    }

    @Test func anEligibleOrderKeepsTheMethod() async throws {
        stubInit(#"{"status":{"state":"SUCCESS"},"plugin_result":{"status":"ELIGIBLE"},"step_id":3}"#)
        let checkout = try await makeCheckout(integrationMode: "redirection")
        defer { Task { await InitGuard.shared.reset() } }

        #expect(initCount() == 1)
        #expect(checkout.paymentMethods.map(\.id) == ["paypal-bnpl"])
    }

    /// Web probes only in redirection mode; the popup flow checks eligibility in PayPal's own SDK.
    @Test func popupModeIsNotProbed() async throws {
        stubInit(#"{"status":{"state":"SUCCESS"},"plugin_result":{"status":"NOT_ELIGIBLE"}}"#)
        _ = try await makeCheckout(integrationMode: "popup")

        #expect(initCount() == 0)
    }

    /// A restored checkout whose payment already left must not `/init` again: on PayPal that is a
    /// second order for a payment in flight.
    @Test func aRestoredSubmittedSessionIsNotProbed() async throws {
        stubInit(#"{"status":{"state":"SUCCESS"},"plugin_result":{"status":"ELIGIBLE"}}"#)
        await InitGuard.shared.reset()
        let saved = CheckoutSavedState(
            widgetData: widgetData(integrationMode: "redirection"),
            lockedEnvironment: nil, disabledMethods: [], instanceId: "restored-bnpl",
            primaryId: nil, secondaries: [], registrationByMethod: [:], registrationBySecondaryToken: [:],
            collectedByItem: [:], submitted: true, savedAt: Date()
        )
        let restored = try PurseHeadlessCheckout.restore(saved, urlSession: StubURLProtocol.session())
        for task in restored.pendingEligibility { await task.value }

        #expect(restored.sessionState == .submitted)
        #expect(initCount() == 0)
    }

    /// Web's bnpl plugin pays on the probe's `/init` alone: a second one would be a second PayPal order.
    @Test func aPaidBNPLCheckoutSendsOneInit() async throws {
        stubInit(#"{"status":{"state":"SUCCESS"},"plugin_result":{"status":"ELIGIBLE"},"step_id":3}"#)
        StubURLProtocol.set("/validate", .ok(#"{"global_status":"SUCCESS","results":[]}"#), host: Self.host)
        let checkout = try await makeCheckout(integrationMode: "redirection")
        defer { Task { await InitGuard.shared.reset() } }
        guard case let .primaryMethod(bnpl)? = checkout.paymentMethods.first else {
            Issue.record("bnpl not listed")
            return
        }
        try checkout.setPrimary(bnpl)

        _ = try await checkout.submitPayment()

        #expect(initCount() == 1)
        let items = try #require(StubURLProtocol.body(for: "/validate", host: Self.host)?.array)
        #expect(items.first?["step_id"] == nil)
    }
}
