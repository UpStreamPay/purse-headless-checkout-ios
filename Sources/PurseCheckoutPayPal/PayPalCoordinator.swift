// Web: packages/partner-ui/src/plugins/partners/paypal/wallet/index.ts (button, createOrder, onApprove)
// Same: /init creates the order, the buyer approves, /validate captures with the step_id.
// Differs: the PayPal iOS SDK's own browser-switch client instead of a JS popup; /init runs on the tap, not at render, so there's no orphan order; the approval URL echoed by /validate is suppressed centrally (see RedirectAction.isPayPalApprovalEcho) rather than per-plugin.

import CorePayments
import Foundation
import PayPalWebPayments
import PurseHeadlessCheckout

/// Drives PayPal's approval for one payment item. A saved PayPal token needs no approval at all —
/// ``authorize()`` short-circuits to marking the item fulfilled, since `preValidation` will `/init`
/// and patch the token itself.
@MainActor
public final class PayPalCoordinator: NSObject {

    private let host: any PluginHost
    private var pending: CheckedContinuation<Void, any Error>?
    private var client: PayPalWebCheckoutClient?

    public init(host: any PluginHost) {
        self.host = host
    }

    /// `/init` for an order, then present PayPal's approval flow and wait for the buyer. On success
    /// the step id (and PayPal's diagnostic order/payer ids) are stashed on the checkout, ready for
    /// the next submit.
    public func authorize() async throws {
        let context = host.buildContext()

        // A saved token has already been approved when it was vaulted — nothing to do here.
        if context.token != nil {
            host.setFulfilled(true)
            return
        }

        // Read the client id BEFORE /init: without it the approval can never open, and failing
        // first leaves no orphan PayPal order behind.
        guard let clientId = context.configuration?.settings.merchantClientId?.nonBlank else {
            throw PartnerUIError(
                "the session carries no merchant_specifics.client_id for "
                    + "\(context.partner.wireValue)/\(context.method.wireValue) — cannot configure the PayPal SDK"
            )
        }

        let initResponse = try await context.api.initPayment(
            PayPalRequestBuilder.initPayload(amount: context.amount, partner: context.partner)
        )
        let orderId = try PayPalRequestBuilder.parseOrderId(initResponse)
        let stepId = try PayPalRequestBuilder.parseStepId(initResponse)

        let client = PayPalWebCheckoutClient(
            config: CoreConfig(clientID: clientId, environment: host.environment.payPalEnvironment)
        )
        client.delegate = self
        self.client = client

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            pending = continuation
            client.start(request: PayPalWebCheckoutRequest(orderID: orderId, fundingSource: .paypal))
        }

        host.setCollected([
            PayPalPlugin.Collected.stepId: stepId.map { .number(String($0)) } ?? .null,
        ])
    }
}

extension PayPalCoordinator: PayPalWebCheckoutDelegate {

    // Delegate callbacks are not documented as arriving on a particular thread, but the SDK's own
    // ASWebAuthenticationSession completion runs on the main queue in practice (it's the same
    // mechanism WebAuthRedirectPresenter uses directly).
    public nonisolated func payPal(
        _ payPalClient: PayPalWebCheckoutClient,
        didFinishWithResult result: PayPalWebCheckoutResult
    ) {
        // Convert to Sendable values *here*, before crossing to the main actor — CoreSDKError and
        // PayPalWebCheckoutResult are not Sendable (Swift 5.9 module, no annotations).
        let orderId = result.orderID
        let payerId = result.payerID
        Task { @MainActor in
            self.host.setCollected([
                PayPalPlugin.Collected.orderId: .string(orderId),
                PayPalPlugin.Collected.payerId: .string(payerId),
            ])
            self.host.setFulfilled(true)
            self.resume(.success(()))
        }
    }

    public nonisolated func payPal(_ payPalClient: PayPalWebCheckoutClient, didFinishWithError error: CoreSDKError) {
        // CoreSDKError is not Sendable; take only what's needed before crossing to the main actor.
        let message = error.localizedDescription
        Task { @MainActor in
            self.resume(.failure(PartnerUIError("PayPal approval failed: \(message)")))
        }
    }

    public nonisolated func payPalDidCancel(_ payPalClient: PayPalWebCheckoutClient) {
        Task { @MainActor in
            self.resume(.failure(PartnerUIError("the shopper cancelled PayPal approval")))
        }
    }

    private func resume(_ result: Result<Void, any Error>) {
        pending?.resume(with: result)
        pending = nil
    }
}

private extension PurseEnvironment {
    /// Purse's environment tiers do not line up one-to-one with PayPal's two: only sandbox and live
    /// exist on PayPal's side, so every non-production tier maps to sandbox — the same rule Apple
    /// Pay's vault-environment mapping uses.
    var payPalEnvironment: CorePayments.Environment {
        switch self {
        case .production: .live
        case .sandbox, .development, .test: .sandbox
        }
    }
}

private extension String {
    var nonBlank: String? { trimmingCharacters(in: .whitespaces).isEmpty ? nil : self }
}
