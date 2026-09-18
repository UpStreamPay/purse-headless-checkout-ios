// Web: packages/partner-ui/src/plugins/generics/applepay/index.ts
// Same: /init for the sheet configuration; partner_data.session + payment_data.card into /validate.
// Differs: no merchant-validation round trip (PassKit has no `onvalidatemerchant`).

import Foundation
import PassKit
import UIKit
import PurseHeadlessCheckout

/// The Apple Pay plugin — the protocol half, no PassKit types. The sheet lives in
/// ``ApplePayCoordinator``.
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

/// Install this to offer Apple Pay: there is no `ServiceLoader` on this platform, so a partner
/// product is linked and installed explicitly, never discovered.
public struct ApplePayModule: PartnerModule {
    public let id = "purse.applepay"

    /// Needed to render a payment element: the merchant id is entitlement-bound, so nothing in the
    /// session carries it. `nil` still registers the plugin — only the element needs it.
    private let configuration: ApplePayConfiguration?

    public init(configuration: ApplePayConfiguration? = nil) {
        self.configuration = configuration
    }

    @MainActor public func register(into registry: PluginRegistry) {
        // A method fallback whatever the partner: the session decides which PSP handles Apple Pay.
        registry.registerFallback(method: .applePay) { ApplePayPlugin(partner: $0.partner) }
    }

    @MainActor public func renders(_ plugin: any PartnerUIPlugin) -> Bool { plugin is ApplePayPlugin }

    @MainActor public func surface(
        for plugin: any PartnerUIPlugin,
        request: SurfaceRequest
    ) -> PaymentSurface? {
        let listener = request.listener
        guard let configuration else {
            return .headless(submit: {
                listener.onOutcome(.failed(PartnerUIError(
                    "Apple Pay needs a merchant id: install ApplePayModule(configuration:)"
                )))
            })
        }
        // Read once: `canPay` is a `static var` nothing can observe.
        guard ApplePayCoordinator.canPay else { return .headless(submit: {}) }

        let coordinator = ApplePayCoordinator(host: request.host, configuration: configuration)
        let button = ApplePayButtonBox(coordinator: coordinator, request: request)

        return PaymentSurface(
            hasUI: true,
            selfSubmitting: true,
            makeView: { button.view },
            prepare: {
                do {
                    try await coordinator.prepare()
                    listener.onReady(true)
                } catch {
                    listener.onReady(false)
                    listener.onOutcome(.failed(error.asPurseError()))
                }
            },
            // Self-submitting: the button drives it. A host Pay button must not.
            submit: {}
        )
    }
}

/// Owns the `PKPaymentButton` and its target, which `UIControl` holds unowned.
@MainActor
private final class ApplePayButtonBox {
    let view: PKPaymentButton
    private let coordinator: ApplePayCoordinator
    private let request: SurfaceRequest

    init(coordinator: ApplePayCoordinator, request: SurfaceRequest) {
        self.coordinator = coordinator
        self.request = request
        self.view = PKPaymentButton(paymentButtonType: .plain, paymentButtonStyle: .automatic)
        view.addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    @objc private func tapped() {
        Task { @MainActor in
            do {
                try await coordinator.present()
            } catch {
                request.listener.onOutcome(.failed(error.asPurseError()))
                return
            }
            await request.selectAndCapture()
        }
    }
}
