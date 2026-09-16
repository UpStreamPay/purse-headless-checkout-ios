// Web: packages/partner-ui/src/plugins/generics/applepay/index.ts
// Same: /init for the sheet configuration; partner_data.session + payment_data.card into /validate.
// Differs: no merchant-validation round trip (PassKit has no `onvalidatemerchant`).

import Foundation
import PurseHeadlessCheckout

/// The Apple Pay plugin — the protocol half, with no PassKit types in sight.
///
/// The sheet lives in ``ApplePayCoordinator``.
public struct ApplePayPlugin: PartnerUIPlugin {

    /// Keys the coordinator uses when handing its result back to the checkout.
    public enum Collected {
        /// The authorized token, already wrapped for this partner's API.
        public static let session = "applePaySession"
        /// `payment.token.transactionIdentifier`.
        public static let fingerprint = "applePayFingerprint"
        /// The network the shopper's chosen card is on, in Payment API vocabulary.
        public static let network = "selected_network"
    }

    public let partner: Partner
    public let method: PaymentMethod = .applePay

    public init(partner: Partner) {
        self.partner = partner
    }

    /// Only an authorized sheet can be submitted — there is nothing to send otherwise.
    public func validateUI(_ context: PartnerUIContext) async throws -> Bool {
        context.collected[Collected.session]?.stringValue != nil
    }

    public func preValidation(_ context: PartnerUIContext) async throws -> ValidateItemPayload {
        guard let session = context.collected[Collected.session]?.stringValue else {
            throw PartnerUIError(
                "Apple Pay token is missing — the payment was not authorized before validation"
            )
        }

        var card: [String: JSONValue] = [:]
        if let fingerprint = context.collected[Collected.fingerprint]?.stringValue {
            card["fingerprint"] = .string(fingerprint)
        }
        if let network = context.collected[Collected.network]?.stringValue {
            card["selected_network"] = .string(network)
        }

        return ItemPayload(
            partner: partner,
            method: method,
            amount: context.amount,
            paymentData: ["card": .object(card)],
            partnerData: [
                "session": .string(session),
                "browser": .object(await BrowserData.make(locale: context.options.locale)),
            ]
        )
    }

}

/// Install this to offer Apple Pay: There is no `ServiceLoader` on this platform, so a partner
/// product is never discovered — it is linked and installed explicitly.
public struct ApplePayModule: PartnerModule {
    public let id = "purse.applepay"

    public init() {}

    @MainActor public func register(into registry: PluginRegistry) {
        // Registered as a method fallback, whatever the partner: the session decides which PSP
        // handles Apple Pay, and the variant is derived from it.
        registry.registerFallback(method: .applePay) { ApplePayPlugin(partner: $0.partner) }
    }
}
