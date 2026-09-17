// Web: packages/partner-ui/src/plugins/partners/paypal/wallet/index.ts (button, createOrder, onApprove)
// Same: /init creates the order, the buyer approves, /validate captures with the step_id.
// Differs: PayPal's browser-switch client, not a JS popup; /init runs on the tap so there is no orphan order; /validate's echoed approval URL is suppressed centrally (RedirectAction.isPayPalApprovalEcho).

import CorePayments
import Foundation
import PayPalWebPayments
import PurseHeadlessCheckout

/// Drives PayPal's approval for one payment item. A saved token needs no approval — ``authorize()``
/// just marks it fulfilled, since `preValidation` will `/init` and patch the token itself.
@MainActor
public final class PayPalCoordinator: NSObject {

    private let host: any PluginHost
    private var pending: CheckedContinuation<Void, any Error>?
    private var client: PayPalWebCheckoutClient?

    public init(host: any PluginHost) {
        self.host = host
    }

    /// `/init` for an order, then present PayPal's approval and wait; on success the step id and
    /// PayPal's diagnostic ids are stashed on the checkout.
    public func authorize() async throws {
        let context = host.buildContext()

        if context.token != nil {
            host.setFulfilled(true)
            return
        }

        // Read the client id BEFORE /init: failing first leaves no orphan PayPal order behind.
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

        // One at a time: a second call would overwrite the continuation and strand the first caller.
        guard pending == nil else {
            throw PartnerUIError("a PayPal approval is already in progress")
        }

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

    // Delegate callbacks document no delivery thread, so every one hops explicitly.
    public nonisolated func payPal(
        _ payPalClient: PayPalWebCheckoutClient,
        didFinishWithResult result: PayPalWebCheckoutResult
    ) {
        // `PayPalWebCheckoutResult` is not Sendable (Swift 5.9 module, no annotations): read the
        // values out here, before crossing.
        let orderId = result.orderID
        let payerId = result.payerID
        Task { @MainActor in
            self.host.setCollected([
                PayPalPlugin.Collected.orderId: .string(orderId),
                PayPalPlugin.Collected.payerId: .string(payerId),
            ])
            self.host.setFulfilled(true)
            // The approval *is* the shopper choosing PayPal — `setAsPrimary`'s contract for a
            // self-submitting flow. Without it the split's primary stays unset and submit refuses.
            do {
                try self.host.setAsPrimary()
            } catch {
                self.resume(.failure(error))
                return
            }
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
    /// PayPal has only sandbox and live, so every non-production Purse tier maps to sandbox.
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
