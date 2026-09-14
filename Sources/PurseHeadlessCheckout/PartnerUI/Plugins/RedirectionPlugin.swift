// Web: packages/partner-ui/src/plugins/generics/redirection/index.ts
// Same: /init at render, step_id + browser into /validate, token patched in.
// Differs: partner and method come from the session, never hardcoded; the redirect is followed by the presenter after submit, not inside postValidation (there is no `window.location`).

import Foundation

/// The **generic redirection** plugin — the protocol half, pure JSON, no UI types.
public struct RedirectionPlugin: PartnerUIPlugin {

    /// The `configurations.template` value this plugin is registered under.
    public static let template = "redirection"

    public let partner: Partner
    public let method: PaymentMethod

    public init(partner: Partner, method: PaymentMethod) {
        self.partner = partner
        self.method = method
    }

    /// `POST /init` → the `step_id` the `/validate` payload carries back, then the item payload.
    /// Web additionally runs an optional per-partner fingerprinting script here; its only entry is
    /// PayPal's Fraudnet, a browser-`<script>` mechanism with no native equivalent.
    public func preValidation(_ context: PartnerUIContext) async throws -> ValidateItemPayload {
        let initResponse = try await context.api.initPayment([
            "partner": .string(partner.wireValue),
            "method": .string(method.wireValue),
            "amount": .number(context.amount.description),
        ])

        let stepId = initResponse["step_id"]?.intValue
            ?? initResponse["results"]?.arrayValue?.first?["step_id"]?.intValue

        var paymentData: [String: JSONValue] = [:]
        if let token = context.token {
            paymentData = token.patch(paymentData)
        }

        return ItemPayload(
            partner: partner,
            method: method,
            amount: context.amount,
            stepId: stepId,
            paymentData: paymentData,
            partnerData: ["browser": .object(Self.browserData)]
        )
    }

    /// The `partner_data.browser` block a 3-D Secure step needs. Native has no `window.navigator`,
    /// so these are the honest native equivalents rather than a spoofed browser fingerprint: an ACS
    /// uses them for challenge sizing and locale.
    static var browserData: [String: JSONValue] {
        [
            "accept_header": "application/json",
            "java_enabled": .bool(false),
            "language": .string(Locale.preferredLanguages.first ?? "en"),
            "color_depth": .number("32"),
            "timezone_offset": .number(String(-TimeZone.current.secondsFromGMT() / 60)),
        ]
    }
}

/// Registers the generic redirection template. Built in — a merchant never installs this one.
struct RedirectionModule: PartnerModule {
    let id = "purse.redirection"

    @MainActor func register(into registry: PluginRegistry) {
        registry.registerGeneric(template: RedirectionPlugin.template) { data in
            RedirectionPlugin(partner: data.partner, method: data.method)
        }
    }
}
