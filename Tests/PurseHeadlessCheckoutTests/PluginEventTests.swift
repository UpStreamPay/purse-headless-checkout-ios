import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// What a plugin reports back to the checkout: `PluginEvent`, `onAmountUpdate` and the
/// `ensureClientCompatibility` probe. Android's `PurseHeadlessCheckoutTest` 357/372/388/1272.
@MainActor
@Suite(.serialized)
struct PluginEventTests {

    private actor StubPlugin: PartnerUIPlugin {
        nonisolated let partner: Partner
        nonisolated let method: PaymentMethod
        nonisolated let incompatible: Bool
        private(set) var amountUpdates: [Decimal] = []

        init(partner: Partner, method: PaymentMethod, incompatible: Bool = false) {
            self.partner = partner
            self.method = method
            self.incompatible = incompatible
        }

        func onAmountUpdate(_ context: PartnerUIContext) async throws {
            amountUpdates.append(context.amount)
        }

        nonisolated func ensureClientCompatibility(_ context: PartnerUIContext) async throws {
            if incompatible { throw PartnerUIError("not on this device") }
        }

        nonisolated func preValidation(_ context: PartnerUIContext) async throws -> ValidateItemPayload {
            ItemPayload(partner: partner, method: method, amount: context.amount)
        }
    }

    private func makeCheckout(plugin: StubPlugin? = nil, incompatible: Bool = false) throws -> PurseHeadlessCheckout {
        let registry = PluginRegistry()
        registry.registerVault(vendor: .purse) {
            plugin ?? StubPlugin(partner: $0.partner, method: $0.method, incompatible: incompatible)
        }
        return try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(paymentSession: TestSessions.paymentSession(amount: 100)),
            registry: registry,
            urlSession: StubURLProtocol.session()
        )
    }

    private func card(_ checkout: PurseHeadlessCheckout) throws -> PrimaryMethod {
        try #require(checkout.paymentMethods.compactMap {
            if case let .primaryMethod(method) = $0 { return method }
            return nil
        }.first)
    }

    private func disabled(_ checkout: PurseHeadlessCheckout, _ id: String) -> DisabledState? {
        checkout.paymentMethods.first { $0.id == id }?.disabled
    }

    @Test func aFatalEventDisablesTheMethodAndClearsItFromTheSplit() throws {
        let checkout = try makeCheckout()
        let method = try card(checkout)
        let host = try checkout.host(for: method)
        try host.setAsPrimary()
        var received: [CheckoutPluginEvent] = []
        checkout.onPluginEvent = { received.append($0) }

        host.dispatch(.clientError(message: "boom"))

        #expect(disabled(checkout, method.id)?.code == .partnerUIFatalError)
        #expect(!checkout.amountSplit.contains { $0.source.id == method.id })
        #expect(received == [CheckoutPluginEvent(itemId: method.id, event: .clientError(message: "boom"))])
        #expect(throws: PurseCheckoutError.self) { try checkout.setPrimary(method) }
    }

    @Test func aRecoverableErrorDimsTheMethodAndReadyBringsItBack() throws {
        let checkout = try makeCheckout()
        let method = try card(checkout)
        let host = try checkout.host(for: method)

        host.dispatch(.partnerError(message: "blip", recoverable: true))
        #expect(disabled(checkout, method.id)?.code == .partnerUIRecoverableError)

        host.dispatch(.ready)
        #expect(disabled(checkout, method.id) == nil)
    }

    @Test func endOfSessionTerminatesTheSession() throws {
        let checkout = try makeCheckout()
        let host = try checkout.host(for: try card(checkout))

        host.dispatch(.endOfSession)

        #expect(checkout.sessionState == .terminated)
    }

    @Test func redirectAndCancelledChangeNothing() throws {
        let checkout = try makeCheckout()
        let method = try card(checkout)
        let host = try checkout.host(for: method)

        host.dispatch(.redirect)
        host.dispatch(.cancelled)

        #expect(disabled(checkout, method.id) == nil)
        #expect(checkout.sessionState == .ready)
    }

    /// Android's `CheckoutTelemetryTest.kt:161`: a refused probe drops the method from the list.
    @Test func anIncompatiblePluginHidesItsMethod() async throws {
        let checkout = try makeCheckout(incompatible: true)
        for task in checkout.pendingEligibility { await task.value }

        #expect(checkout.paymentMethods.isEmpty)
    }

    @Test func aCompatiblePluginKeepsItsMethod() async throws {
        let checkout = try makeCheckout()
        for task in checkout.pendingEligibility { await task.value }

        #expect(checkout.paymentMethods.count == 1)
    }

    /// Fires when the remaining amount moves, never on a refresh that leaves it where it was.
    @Test func onAmountUpdateFiresOnlyWhenTheRemainingAmountMoves() async throws {
        let plugin = StubPlugin(partner: .purse, method: .creditCard)
        let checkout = try makeCheckout(plugin: plugin)
        let method = try card(checkout)
        _ = try checkout.host(for: method)

        checkout.setFulfilled(method.id, false)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await plugin.amountUpdates.isEmpty)

        try checkout.setSession(TestSessions.widgetData(
            paymentSession: TestSessions.paymentSession(id: "session-2", amount: 80)
        ))
        for _ in 0..<20 where await plugin.amountUpdates.isEmpty {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(await plugin.amountUpdates == [80])
    }

    @Test func eachPartnerMethodNamesTheProductThatShipsIt() {
        #expect(PartnerProducts.product(partner: .adyen, method: .applePay) == "PurseCheckoutApplePay")
        #expect(PartnerProducts.product(partner: .klarna, method: .installments) == "PurseCheckoutKlarna")
        #expect(PartnerProducts.product(partner: .paypal, method: .wallet) == "PurseCheckoutPayPal")
        #expect(PartnerProducts.product(partner: .purse, method: .creditCard) == nil)
    }
}
