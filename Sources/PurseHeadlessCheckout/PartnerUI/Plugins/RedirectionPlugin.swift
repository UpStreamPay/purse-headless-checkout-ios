// Web: packages/partner-ui/src/plugins/generics/redirection/index.ts
// Same: /init at render, step_id + browser into /validate, token patched in.
// Differs: partner and method come from the session; the redirect is followed by the presenter after submit, not inside postValidation (there is no `window.location`); PayPal bnpl's eligibility probe (web's `partners/paypal/bnpl` `ensureClientCompatibility`) lives here, since redirection mode is the only one iOS serves it in and it needs no PayPal SDK; its `/validate` then carries no step id and no second `/init`, as web's bnpl plugin (`step_id` omitted rather than `null`).

import Foundation

/// The generic redirection plugin — the protocol half, no UI types.
public struct RedirectionPlugin: PartnerUIPlugin {

    /// The `configurations.template` value this plugin is registered under.
    public static let template = "redirection"

    public let partner: Partner
    public let method: PaymentMethod

    public init(partner: Partner, method: PaymentMethod) {
        self.partner = partner
        self.method = method
    }

    /// Web's PayPal bnpl probe: in redirection mode, an `/init` whose `plugin_result.status` is
    /// `NOT_ELIGIBLE` withdraws the method. Any other failure withdraws it too, as on web.
    public func ensureClientCompatibility(_ context: PartnerUIContext) async throws {
        guard isPayPalBNPL(context) else { return }
        let response = try await context.api.initPayment([
            "partner": .string(partner.wireValue),
            "method": .string(method.wireValue),
            "amount": .number(context.amount.description),
            "partner_data": .object([:]),
            "payment_data": .object([:]),
            "payment_preferences": .object([:]),
        ])
        if response["plugin_result"]?["status"]?.stringValue == "NOT_ELIGIBLE" {
            throw PartnerUIError("PayPal BNPL is not eligible for this order")
        }
    }

    /// Web also runs a per-partner fingerprinting script here; its only entry is PayPal's Fraudnet,
    /// a browser-`<script>` mechanism with no native equivalent.
    public func preValidation(_ context: PartnerUIContext) async throws -> ValidateItemPayload {
        // Web's bnpl plugin: the probe's `/init` was the only one, `/validate` goes without a step id.
        if isPayPalBNPL(context) {
            return ItemPayload(partner: partner, method: method, amount: context.amount)
        }
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
            partnerData: ["browser": .object(await BrowserData.make(locale: context.options.locale))]
        )
    }
}

extension RedirectionPlugin {
    func isPayPalBNPL(_ context: PartnerUIContext) -> Bool {
        partner == .paypal && method == .bnpl && context.configuration?.settings.integrationMode == .redirection
    }
}

/// Built in — a merchant never installs this one.
struct RedirectionModule: PartnerModule {
    let id = "purse.redirection"

    @MainActor func register(into registry: PluginRegistry) {
        registry.registerGeneric(template: RedirectionPlugin.template) { data in
            RedirectionPlugin(partner: data.partner, method: data.method)
        }
    }

    @MainActor func renders(_ plugin: any PartnerUIPlugin) -> Bool { plugin is RedirectionPlugin }

    /// Nothing to show: the PSP's hosted page is the payment step, and `/init` runs inside
    /// `preValidation`, so there is nothing to prepare either.
    @MainActor func surface(for plugin: any PartnerUIPlugin, request: SurfaceRequest) -> PaymentSurface? {
        PaymentSurface.headless(
            prepare: { request.listener.onReady(true) },
            submit: { await request.captureNow() }
        )
    }
}
