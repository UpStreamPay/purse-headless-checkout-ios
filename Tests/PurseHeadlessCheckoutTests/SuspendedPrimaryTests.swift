import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// SDK-12555, web's SDK-12349: an engaged primary that the rest to pay puts out of its bounds is
/// taken out of the split, so it can no longer reach `/validate`.
@MainActor
@Suite(.serialized)
struct SuspendedPrimaryTests {

    /// A fictional root: all four tiers are claimed by other suites.
    private static let host = "api.suspendedprimary.example"

    private struct StubCardPlugin: PartnerUIPlugin {
        let partner: Partner
        let method: PaymentMethod
        func preValidation(_ context: PartnerUIContext) async throws -> ValidateItemPayload {
            ItemPayload(partner: partner, method: method, amount: context.amount)
        }
    }

    private func makeCheckout(amount: Decimal, cardSettings: [String: Any]) throws -> PurseHeadlessCheckout {
        var protocols = TestSessions.cardProtocol(settings: cardSettings)
        protocols["illicado"] = ["giftcard": ["configurations": [
            "stable": true, "labels": ["secondary"], "settings": [:],
        ]]]
        let registry = PluginRegistry()
        registry.registerVault(vendor: .purse) { StubCardPlugin(partner: $0.partner, method: $0.method) }
        return try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(
                apiURL: "https://\(Self.host)/payment/v1",
                paymentSession: TestSessions.paymentSession(
                    id: "suspended-primary", amount: NSDecimalNumber(decimal: amount), protocols: protocols
                )
            ),
            registry: registry,
            urlSession: StubURLProtocol.session()
        )
    }

    private func giftCard(balance: Decimal) -> SecondaryToken {
        SecondaryToken(
            id: "illicado-giftcard-1234", partner: .illicado, method: .giftCard,
            pan: "9250000000001234", cvv: nil, name: "", balance: balance
        )
    }

    private func card(_ checkout: PurseHeadlessCheckout) throws -> PrimaryMethod {
        try #require(checkout.paymentMethods.compactMap { item -> PrimaryMethod? in
            if case let .primaryMethod(method) = item { return method }
            return nil
        }.first)
    }

    /// The QA case: younited cb6x, max 475 €, 479 € order.
    @Test func aPrimaryPushedOverItsMaxIsNoLongerPayable() async throws {
        StubURLProtocol.reset(host: Self.host)
        let checkout = try makeCheckout(amount: 479, cardSettings: ["payment_max_amount": 475])
        let gift = giftCard(balance: 10)

        try checkout.applySecondary(gift)
        try checkout.setPrimary(try card(checkout))
        #expect(checkout.isPaymentFulfilled)

        checkout.removeSecondary(gift)

        #expect(try card(checkout).disabled?.code == .maxAmountExceeded)
        #expect(!checkout.isPaymentFulfilled)
        #expect(checkout.amountSplit.isEmpty)
        await #expect(throws: PurseCheckoutError.self) { _ = try await checkout.submitPayment() }
        #expect(!StubURLProtocol.paths(host: Self.host).contains { $0.hasSuffix("/validate") })
    }

    /// Web dropped the engaged-item exemption for primaries: a minimum it no longer meets clears it too.
    @Test func aPrimaryPushedUnderItsMinIsNoLongerPayable() async throws {
        StubURLProtocol.reset(host: Self.host)
        let checkout = try makeCheckout(amount: 100, cardSettings: ["payment_min_amount": 50])

        try checkout.setPrimary(try card(checkout))
        try checkout.applySecondary(giftCard(balance: 60))

        #expect(try card(checkout).disabled?.code == .minAmountNotMet)
        #expect(!checkout.isPaymentFulfilled)
    }

    @Test func aPrimaryWithinItsBoundsStaysEngaged() throws {
        StubURLProtocol.reset(host: Self.host)
        let checkout = try makeCheckout(amount: 100, cardSettings: ["payment_max_amount": 475])

        try checkout.setPrimary(try card(checkout))
        try checkout.applySecondary(giftCard(balance: 10))

        #expect(checkout.isPaymentFulfilled)
        #expect(checkout.amountSplit.count == 2)
    }

    /// Web's second half of SDK-12349: a host that outlived a `setSession` engages nothing stale.
    @Test func aPrimaryFromAPreviousSessionIsNotEngaged() throws {
        StubURLProtocol.reset(host: Self.host)
        let checkout = try makeCheckout(amount: 100, cardSettings: [:])
        let stale = try card(checkout)
        try checkout.setSession(TestSessions.widgetData(
            apiURL: "https://\(Self.host)/payment/v1",
            paymentSession: TestSessions.paymentSession(id: "suspended-primary-2", amount: 100, protocols: [:])
        ))

        #expect(throws: PurseCheckoutError.self) { try checkout.setPrimary(stale) }
        #expect(checkout.amountSplit.isEmpty)
    }
}
