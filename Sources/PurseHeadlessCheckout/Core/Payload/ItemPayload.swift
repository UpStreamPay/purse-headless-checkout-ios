// Web: packages/model `ItemPayload` / `ValidateItemPayload`
// Same: same wire shape (`partner_data`, `payment_data`, `payment_preferences`, `step_id`).
// Differs: free-form bodies are `JSONValue`, not `org.json.JSONObject`.

import Foundation

/// A single item in a Payment API `/init` or `/validate` request. The stable envelope (`partner`,
/// `method`, `amount`, `step_id`) is modelled; the partner-specific bodies stay free-form
/// ``JSONValue`` since only a plugin knows their shape — JSON stays at the edges.
public struct ItemPayload: Sendable, Equatable {
    public let partner: Partner
    public let method: PaymentMethod
    public let amount: Decimal
    public let stepId: Int?
    public let paymentData: [String: JSONValue]
    public let partnerData: [String: JSONValue]
    public let order: [String: JSONValue]
    public let paymentPreferences: [String: JSONValue]

    public init(
        partner: Partner,
        method: PaymentMethod,
        amount: Decimal,
        stepId: Int? = nil,
        paymentData: [String: JSONValue] = [:],
        partnerData: [String: JSONValue] = [:],
        order: [String: JSONValue] = [:],
        paymentPreferences: [String: JSONValue] = [:]
    ) {
        self.partner = partner
        self.method = method
        self.amount = amount
        self.stepId = stepId
        self.paymentData = paymentData
        self.partnerData = partnerData
        self.order = order
        self.paymentPreferences = paymentPreferences
    }

    /// Serializes to the wire shape. `payment_data.vault_vendor` defaults to `"none"` when the
    /// plugin did not set it — mirroring web's `normalizePaymentData`.
    public func toJSON() -> JSONValue {
        var normalizedPaymentData = paymentData
        if normalizedPaymentData["vault_vendor"] == nil {
            normalizedPaymentData["vault_vendor"] = .string(VaultVendor.none.wireValue)
        }

        var object: [String: JSONValue] = [
            "partner": .string(partner.wireValue),
            "method": .string(method.wireValue),
            "amount": .number(amount.description),
            "payment_data": .object(normalizedPaymentData),
            "partner_data": .object(partnerData),
            "order": .object(order),
            "payment_preferences": .object(paymentPreferences),
        ]
        if let stepId {
            object["step_id"] = .number(String(stepId))
        }
        return .object(object)
    }
}

/// The `/validate` body is a JSON array of these — same shape as ``ItemPayload``, as in web.
public typealias ValidateItemPayload = ItemPayload
