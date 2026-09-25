import Foundation
import Testing
@testable import PurseCheckoutPayPal
@testable import PurseHeadlessCheckout

/// PayPal's `/init` shape and what reaches `/validate`. The approval flow needs a real device and
/// a configured merchant client id, so it is not unit tested.
@Suite(.serialized)
@MainActor
struct PayPalTests {

    /// This suite's own host, so its stubbed /init cannot collide with another suite's.
    private static let host = "api.paypaltest.example"

    private func context(
        token: PayToken? = nil,
        collected: [String: JSONValue] = [:]
    ) throws -> PartnerUIContext {
        let params = try SessionCodec.decode(TestSessions.widgetData())
        return PartnerUIContext(
            partner: .paypal,
            method: .wallet,
            session: params.paymentSession,
            amount: 100,
            api: PaymentAPIClient(
                apiKey: "k", apiRoot: "https://\(Self.host)/payment/v1",
                entityId: "e", sessionId: "s", session: StubURLProtocol.session()
            ),
            token: token,
            collected: collected
        )
    }

    private func stubInit(_ body: String = #"{"status":{"state":"SUCCESS"},"step_id":7}"#) {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/init", .ok(body), host: Self.host)
    }

    // MARK: /init body

    @Test func initPayloadIsPayNowWithNoRegistration() {
        let payload = PayPalRequestBuilder.initPayload(amount: 42, partner: .paypal)
        #expect(payload["partner"]?.stringValue == "paypal")
        #expect(payload["method"]?.stringValue == "wallet")
        #expect(payload["amount"]?.decimalValue == 42)
        #expect(payload["payment_data"]?["vault_vendor"]?.stringValue == "none")
        // Pay-now only: vaulting is out of scope, so registration is always declined.
        #expect(payload["payment_preferences"]?["registration"]?.boolValue == false)
    }

    // MARK: Parsing /init's response

    @Test func parsesTheOrderIdFromLogs() throws {
        let response = JSONValue.object([
            "status": .object(["state": "SUCCESS"]),
            "plugin_result": .object(["logs": .object(["order_id": "ORDER-1"])]),
        ])
        #expect(try PayPalRequestBuilder.parseOrderId(response) == "ORDER-1")
    }

    /// The flatter shapes the same field has been seen in, tried in order.
    @Test func fallsBackToFlatterOrderIdShapes() throws {
        let nested = JSONValue.object([
            "status": .object(["state": "SUCCESS"]),
            "plugin_result": .object(["order_id": "ORDER-2"]),
        ])
        #expect(try PayPalRequestBuilder.parseOrderId(nested) == "ORDER-2")

        let flat = JSONValue.object(["status": .object(["state": "SUCCESS"]), "order_id": "ORDER-3"])
        #expect(try PayPalRequestBuilder.parseOrderId(flat) == "ORDER-3")
    }

    /// Without an order id there is nothing for the buyer to approve — a user-facing failure, not a
    /// silently empty result.
    @Test func noOrderIdIsRefused() {
        let response = JSONValue.object(["status": .object(["state": "SUCCESS"])])
        #expect(throws: PartnerUIError.self) { try PayPalRequestBuilder.parseOrderId(response) }
    }

    @Test func aRefusedInitThrows() {
        let response = JSONValue.object(["status": .object(["state": "FAILED", "description": "nope"])])
        #expect(throws: PaymentAPIError.self) { try PayPalRequestBuilder.parseOrderId(response) }
        #expect(throws: PaymentAPIError.self) { try PayPalRequestBuilder.parseStepId(response) }
    }

    @Test func parsesTheStepId() throws {
        let response = JSONValue.object(["status": .object(["state": "SUCCESS"]), "step_id": .number("9")])
        #expect(try PayPalRequestBuilder.parseStepId(response) == 9)
    }

    /// The saved-token init creates no order, so only its status is checked, never an order_id.
    @Test func aTokenInitWithNoOrderIdStillReportsSuccess() throws {
        let response = JSONValue.object(["status": .object(["state": "SUCCESS"])])
        #expect(try PayPalRequestBuilder.parseStepId(response) == nil)
    }

    // MARK: preValidation — fresh pay-now

    @Test func freshPaymentCarriesTheApprovedStepId() async throws {
        let payload = try await PayPalPlugin(partner: .paypal).preValidation(
            context(collected: [PayPalPlugin.Collected.stepId: .number("7")])
        )
        #expect(payload.stepId == 7)
        #expect(payload.method == .wallet)
    }

    /// PayPal records approval against the order itself, so orderId/payerId are diagnostics here
    /// and must not reach the payload.
    @Test func noBuyerDataIsSentForAFreshPayment() async throws {
        let payload = try await PayPalPlugin(partner: .paypal).preValidation(context(collected: [
            PayPalPlugin.Collected.stepId: .number("7"),
            PayPalPlugin.Collected.orderId: "ORDER-1",
            PayPalPlugin.Collected.payerId: "PAYER-1",
        ]))
        #expect(payload.paymentData.isEmpty)
    }

    /// Without an approval, submitting would send an unapproved order — refused instead.
    @Test func submittingWithoutApprovalIsRefused() async throws {
        let plugin = PayPalPlugin(partner: .paypal)
        #expect(try await !plugin.validateUI(context()))
        await #expect(throws: PartnerUIError.self) { _ = try await plugin.preValidation(try context()) }
    }

    // MARK: preValidation — saved token

    /// A saved token needs no CVV — there is no card behind PayPal at all.
    @Test func aSavedTokenPassesValidateUIWithNoApproval() async throws {
        // validateUI never touches the network for a saved token — no stub needed.
        let token = PayToken(value: "tok-1", requiresCVV: false)
        #expect(try await PayPalPlugin(partner: .paypal).validateUI(context(token: token)))
    }

    @Test func aSavedTokenPatchesItsValueAndSkipsTheCardBlock() async throws {
        stubInit()
        let token = PayToken(value: "tok-1", holderName: "A Shopper", requiresCVV: false)
        let payload = try await PayPalPlugin(partner: .paypal).preValidation(context(token: token))

        #expect(payload.paymentData["token"]?.stringValue == "tok-1")
        #expect(payload.paymentData["holder"]?.stringValue == "A Shopper")
        // No expiry, no network — a PayPal token has no card behind it.
        #expect(payload.paymentData["card"] == nil)
    }

    // MARK: Registration

    @Test func theModuleRegistersExactlyPayPalWallet() throws {
        let registry = PluginRegistry()
        registry.install(PayPalModule())

        let protocols = ["paypal": ["wallet": ["configurations": ["stable": true, "labels": [], "settings": [:]]]]]
        let session = try SessionCodec.decode(
            TestSessions.widgetData(paymentSession: TestSessions.paymentSession(protocols: protocols))
        ).paymentSession

        let plugin = registry.plugin(partner: .paypal, method: .wallet, session: session)
        #expect(plugin is PayPalPlugin)
    }

    // MARK: The approval-echo suppression

    /// PayPal's own approval page, echoed back on the very call that already captured the payment,
    /// must never be re-opened.
    @Test func theApprovalEchoIsSuppressed() {
        let response = JSONValue.object([
            "global_status": "SUCCESS",
            "results": .array([]),
            "redirection": .object(["url": "https://www.sandbox.paypal.com/checkoutnow?token=ORDER-1"]),
        ])
        let action = RedirectionResolver.resolve(validateResponse: response, partner: "paypal", method: "wallet")
        #expect(action == nil)
    }

    @Test func theVaultApprovalEchoIsAlsoSuppressed() {
        #expect("https://paypal.com/agreements/approve?token=x".isPayPalApprovalEcho)
        #expect("https://www.sandbox.paypal.com/checkoutnow?token=x".isPayPalApprovalEcho)
        #expect(!"https://acs.bank.example/3ds".isPayPalApprovalEcho)
    }

    /// Pay Later has no native approval step, so the same URL is the approval and must be followed.
    @Test func theBnplApprovalIsFollowed() {
        let url = "https://www.sandbox.paypal.com/checkoutnow?token=ORDER-1"
        let response = JSONValue.object([
            "global_status": "SUCCESS",
            "results": .array([]),
            "redirection": .object(["url": .string(url)]),
        ])
        let action = RedirectionResolver.resolve(validateResponse: response, partner: "paypal", method: "bnpl")
        #expect(action == .get(url: url))
    }

    /// A genuine redirect for a *different* method must not be caught by this suppression.
    @Test func aGenuineRedirectIsUnaffected() {
        let response = JSONValue.object([
            "results": .array([]),
            "redirection": .object(["url": "https://acs.bank.example/3ds"]),
        ])
        let action = RedirectionResolver.resolve(validateResponse: response, partner: "purse", method: "creditcard")
        #expect(action == .get(url: "https://acs.bank.example/3ds"))
    }
}
