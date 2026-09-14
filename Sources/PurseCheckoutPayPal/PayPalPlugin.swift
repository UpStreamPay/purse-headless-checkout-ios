// Web: packages/partner-ui/src/plugins/partners/paypal/wallet/index.ts
// Same: /init creates the order, /validate captures; token mode patches payment_data.token.
// Differs: no CVV path exists at all here (there never was one — a PayPal token carries no card).

import Foundation
import PurseHeadlessCheckout

/// The PayPal **wallet** (pay-now) plugin — the protocol half, no PayPal SDK types in sight. PayPal
/// is the one method whose native step is a full round trip *out of the app and back*, and it
/// happens **before** `/validate`:.
public struct PayPalPlugin: PartnerUIPlugin {

    /// Keys ``PayPalCoordinator`` uses in `setCollected` for what the approval produced.
    public enum Collected {
        /// The `/init` step id — required to submit; nothing else can be sent without it.
        public static let stepId = "paypalStepId"
        /// The approved PayPal order id. Diagnostic only, never sent to `/validate`.
        public static let orderId = "paypalOrderId"
        /// PayPal's payer id. Diagnostic only, never sent to `/validate`.
        public static let payerId = "paypalPayerId"
    }

    public let partner: Partner
    public let method: PaymentMethod = .wallet

    public init(partner: Partner) {
        self.partner = partner
    }

    /// A saved token needs no approval and so no collected step id; a fresh pay-now item does.
    public func validateUI(_ context: PartnerUIContext) async throws -> Bool {
        if context.token != nil { return true }
        return context.collected[Collected.stepId]?.intValue != nil
    }

    public func preValidation(_ context: PartnerUIContext) async throws -> ValidateItemPayload {
        if let token = context.token {
            let initResponse = try await context.api.initPayment(
                PayPalRequestBuilder.initPayload(amount: context.amount, partner: partner)
            )
            let stepId = try PayPalRequestBuilder.parseStepId(initResponse)
            return ItemPayload(
                partner: partner,
                method: method,
                amount: context.amount,
                stepId: stepId,
                paymentData: token.patch()
            )
        }

        guard let stepId = context.collected[Collected.stepId]?.intValue else {
            throw PartnerUIError(
                "PayPal step id is missing — the buyer must approve the order before submitting"
            )
        }
        return ItemPayload(partner: partner, method: method, amount: context.amount, stepId: stepId)
    }
}

/// Builds the `/init` body for a PayPal wallet payment and parses its response. Pure JSON + session
/// data — no PayPal SDK types (those live in ``PayPalCoordinator``).
enum PayPalRequestBuilder {

    static func initPayload(amount: Decimal, partner: Partner) -> [String: JSONValue] {
        [
            "partner": .string(partner.wireValue),
            "method": .string(PaymentMethod.wallet.wireValue),
            "amount": .number(amount.description),
            "partner_data": .object([:]),
            "payment_data": .object(["vault_vendor": "none"]),
            "payment_preferences": .object(["registration": .bool(false)]),
        ]
    }

    /// The PayPal order id off `/init`'s response, with the flatter shapes it's also been seen in.
    static func parseOrderId(_ response: JSONValue) throws -> String {
        try ensureSucceeded(response)
        let pluginResult = response["plugin_result"]
        if let orderId = pluginResult?["logs"]?["order_id"]?.stringValue { return orderId }
        if let orderId = pluginResult?["order_id"]?.stringValue { return orderId }
        if let orderId = response["order_id"]?.stringValue { return orderId }
        throw PartnerUIError("PayPal init returned no order_id")
    }

    /// The top-level `step_id` `/init` returns for this item.
    static func parseStepId(_ response: JSONValue) throws -> Int? {
        try ensureSucceeded(response)
        return response["step_id"]?.intValue
    }

    /// Fails on a `/init` whose `status.state` is anything but `SUCCESS` — the status half of
    /// order-id parsing, on its own for the **saved-token** `/init`, which creates no order for the
    /// buyer to approve and so carries no `order_id` to parse.
    static func ensureSucceeded(_ response: JSONValue) throws {
        let state = response["status"]?["state"]?.stringValue ?? ""
        guard state.isEmpty || state == "SUCCESS" else {
            let description = response["status"]?["description"]?.stringValue ?? ""
            throw PaymentAPIError(
                "paypal init not successful (state=\(state)) \(description)"
                    .trimmingCharacters(in: .whitespaces),
                path: "/init"
            )
        }
    }
}

/// Registers the PayPal wallet plugin. Install this to offer PayPal:
public struct PayPalModule: PartnerModule {
    public let id = "purse.paypal"

    public init() {}

    @MainActor public func register(into registry: PluginRegistry) {
        registry.register(partner: .paypal, method: .wallet) { PayPalPlugin(partner: $0.partner) }
    }
}
