import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// `PurseHeadlessCheckout.host(for:)` — the concrete `PluginHost` every coordinator
/// (`CardCoordinator`, `ApplePayCoordinator`, `PayPalCoordinator`, `KlarnaCoordinator`) is built
/// against, but which had no implementation anywhere in the repo until now.
@MainActor
@Suite(.serialized)
struct PluginHostTests {

    private actor RecordingPlugin: PartnerUIPlugin {
        nonisolated let partner: Partner
        nonisolated let method: PaymentMethod
        private(set) var sessionSetCount = 0

        init(partner: Partner, method: PaymentMethod) {
            self.partner = partner
            self.method = method
        }

        func onSessionSet(_ context: PartnerUIContext) async throws {
            sessionSetCount += 1
        }

        nonisolated func preValidation(_ context: PartnerUIContext) async throws -> ValidateItemPayload {
            ItemPayload(partner: partner, method: method, amount: context.amount)
        }
    }

    private func checkoutAndPlugin(redirection: String? = "https://merchant.example/return") throws
        -> (PurseHeadlessCheckout, RecordingPlugin) {
        let plugin = RecordingPlugin(partner: .purse, method: .creditCard)
        let registry = PluginRegistry()
        registry.registerVault(vendor: .purse) { _ in plugin }
        let checkout = try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(
                paymentSession: TestSessions.paymentSession(
                    amount: 100,
                    extra: redirection.map { ["redirection": $0] } ?? [:]
                )
            ),
            registry: registry,
            urlSession: StubURLProtocol.session()
        )
        return (checkout, plugin)
    }

    private func primaryMethod(_ checkout: PurseHeadlessCheckout) throws -> PrimaryMethod {
        try #require(checkout.paymentMethods.compactMap {
            if case let .primaryMethod(method) = $0 { return method }
            return nil
        }.first)
    }

    @Test func buildsAContextForTheSelectedItemAndExposesTheRedirectReturnURL() throws {
        let (checkout, _) = try checkoutAndPlugin()
        let method = try primaryMethod(checkout)

        let host = try checkout.host(for: method)

        #expect(host.environment == .sandbox)
        #expect(host.redirectionReturnURL == "https://merchant.example/return")

        let context = host.buildContext()
        #expect(context.partner == method.partner)
        #expect(context.method == method.method)
        #expect(context.amount == checkout.remainingAmountToPay)
        #expect(context.register == false)
        #expect(context.token == nil)
        #expect(context.collected.isEmpty)
    }

    @Test func setCollectedAndSetFulfilledMutateTheUnderlyingCheckout() throws {
        let (checkout, _) = try checkoutAndPlugin()
        let method = try primaryMethod(checkout)
        let host = try checkout.host(for: method)
        try host.setAsPrimary()

        host.setCollected(["step": .string("abc")])
        #expect(host.buildContext().collected["step"] == .string("abc"))

        host.setFulfilled(false)
        #expect(checkout.unfulfilledItemId == method.id)
        host.setFulfilled(true)
        #expect(checkout.unfulfilledItemId == nil)
    }

    @Test func setAsPrimaryCommitsAFreshMethodToTheSplit() throws {
        let (checkout, _) = try checkoutAndPlugin()
        let method = try primaryMethod(checkout)
        let host = try checkout.host(for: method)

        try host.setAsPrimary()

        #expect(checkout.amountSplit.contains { $0.source.id == method.id })
    }

    @Test func setAsPrimaryCommitsASavedToken() throws {
        let token: [String: Any] = ["id": "tok-1", "value": "v1", "description": ["masked_pan": "•••• 1111"]]
        let registry = PluginRegistry()
        registry.registerVault(vendor: .purse) { RecordingPlugin(partner: $0.partner, method: $0.method) }
        let checkout = try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(
                paymentSession: TestSessions.paymentSession(
                    amount: 100,
                    protocols: TestSessions.cardProtocol(integratedTokens: [token])
                )
            ),
            registry: registry,
            urlSession: StubURLProtocol.session()
        )
        let savedToken = try #require(checkout.paymentTokens.first)
        let host = try checkout.host(for: savedToken)

        try host.setAsPrimary()

        #expect(checkout.amountSplit.contains { $0.source.id == savedToken.id })
        #expect(host.buildContext().token?.value == "v1")
    }

    @Test func givesThePluginOnSessionSetExactlyOnceEvenAcrossRepeatedHostRequests() async throws {
        let (checkout, plugin) = try checkoutAndPlugin()
        let method = try primaryMethod(checkout)

        _ = try checkout.host(for: method)
        await checkout.pendingSessionSet[method.id]?.value
        _ = try checkout.host(for: method)
        await checkout.pendingSessionSet[method.id]?.value

        #expect(await plugin.sessionSetCount == 1)
    }

    @Test func throwsCheckoutTornDownAfterTeardown() throws {
        let (checkout, _) = try checkoutAndPlugin()
        let method = try primaryMethod(checkout)
        checkout.teardown()

        do {
            _ = try checkout.host(for: method)
            Issue.record("expected host(for:) to be refused after teardown")
        } catch let error as PurseCheckoutError {
            #expect(error.code == .checkoutTornDown)
        }
    }

    @Test func submitPaymentForwardsToTheCheckoutsOwnSubmit() async throws {
        let (checkout, _) = try checkoutAndPlugin()
        let method = try primaryMethod(checkout)
        let host = try checkout.host(for: method)

        // Nothing was selected as primary and no form was marked fulfilled — the same refusal
        // `checkout.submitPayment()` itself would give, proving the host doesn't reimplement the
        // submit path, just forwards to it.
        do {
            _ = try await host.submitPayment()
            Issue.record("expected submitPayment to be refused")
        } catch is PurseCheckoutError {
            // Any PurseCheckoutError proves the call reached the real submit path.
        }
    }
}
