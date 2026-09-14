// Web: packages/partner-ui/src/plugins/generics/applepay/utils.ts (buildAndBeginApplePaySession)
// Same: configuration from /init, token + fingerprint + network captured on authorization.
// Differs: PKPaymentAuthorizationController instead of ApplePaySession, and no merchant validation.

import Foundation
import PassKit
import PurseHeadlessCheckout

/// Presents the Apple Pay sheet for one payment item.
@MainActor
public final class ApplePayCoordinator: NSObject {

    private let host: any PluginHost
    private let configuration: ApplePayConfiguration
    private let variant: ApplePayVariant
    private var request: ApplePayRequestConfiguration?
    private var controller: PKPaymentAuthorizationController?
    private var pending: CheckedContinuation<Void, any Error>?
    /// Set on authorization; distinguishes "the shopper cancelled" from "the sheet closed after
    /// paying", which arrive through the same delegate callback.
    private var authorized = false

    public init(host: any PluginHost, configuration: ApplePayConfiguration) {
        self.host = host
        self.configuration = configuration
        self.variant = ApplePayVariant.of(host.buildContext().partner)
    }

    /// Whether this device can pay at all. Hide the button when `false` — Apple requires it not be
    /// shown to someone who cannot use it.
    public static var canPay: Bool {
        PKPaymentAuthorizationController.canMakePayments()
    }

    /// Whether a card is actually set up for the networks this session accepts.
    public func canPayWithConfiguredNetworks() -> Bool {
        guard let request else { return Self.canPay }
        return PKPaymentAuthorizationController.canMakePayments(usingNetworks: request.supportedNetworks)
    }

    /// `POST /init` for the sheet configuration.
    ///
    /// - Throws: ``PartnerUIError`` when `/init` returns nothing usable.
    public func prepare() async throws {
        let context = host.buildContext()
        let response = try await context.api.initPayment([
            "partner": .string(context.partner.wireValue),
            "method": .string(PaymentMethod.applePay.wireValue),
            "amount": .number(context.amount.description),
            "partner_data": .object(["browser": .object(ApplePayPlugin.browserData(locale: context.options.locale))]),
            "payment_data": .object([:]),
            "payment_preferences": .object([:]),
        ])

        request = try ApplePayRequestConfiguration.from(
            initResponse: response,
            variant: variant,
            fallbackMerchantName: context.session.id
        )
    }

    /// Present the sheet and wait for the shopper. On success the authorized token is stashed on
    /// the checkout, ready for the next submit.
    public func present() async throws {
        guard let request else {
            throw PartnerUIError("call prepare() before present() — the sheet has no configuration yet")
        }

        let paymentRequest = PKPaymentRequest()
        paymentRequest.merchantIdentifier = configuration.merchantIdentifier
        paymentRequest.countryCode = request.countryCode
        paymentRequest.currencyCode = request.currencyCode
        paymentRequest.merchantCapabilities = request.merchantCapabilities
        paymentRequest.supportedNetworks = request.supportedNetworks
        paymentRequest.paymentSummaryItems = [
            PKPaymentSummaryItem(
                label: request.merchantName,
                amount: NSDecimalNumber(decimal: host.buildContext().amount)
            ),
        ]

        authorized = false
        let controller = PKPaymentAuthorizationController(paymentRequest: paymentRequest)
        controller.delegate = self
        self.controller = controller

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            pending = continuation
            controller.present { presented in
                guard !presented else { return }
                MainActor.assumeIsolated {
                    // PassKit refuses to present without saying why, and the cause is almost always
                    // the entitlement.
                    self.resume(.failure(PartnerUIError(
                        """
                        the Apple Pay sheet could not be presented. The usual causes, in order:
                        (1) '\(self.configuration.merchantIdentifier)' is not listed in this app's \
                        com.apple.developer.in-app-payments entitlement, or is misspelled against it \
                        — enable Apple Pay in Xcode's Signing & Capabilities and check the identifier \
                        matches exactly;
                        (2) no payment processing certificate has been issued for that merchant ID \
                        with this PSP;
                        (3) the request's country/currency/networks are not usable on this device.
                        """
                    )))
                }
            }
        }
    }

    private func resume(_ result: Result<Void, any Error>) {
        pending?.resume(with: result)
        pending = nil
    }
}

extension ApplePayCoordinator: PKPaymentAuthorizationControllerDelegate {

    public func paymentAuthorizationController(
        _ controller: PKPaymentAuthorizationController,
        didAuthorizePayment payment: PKPayment,
        handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
    ) {
        guard let session = ApplePayTokenEnvelope.session(
            for: variant,
            token: payment.token,
            productId: request?.productId
        ) else {
            completion(PKPaymentAuthorizationResult(status: .failure, errors: nil))
            resume(.failure(PartnerUIError("the Apple Pay token could not be read")))
            return
        }

        var collected: [String: JSONValue] = [ApplePayPlugin.Collected.session: .string(session)]
        if let fingerprint = payment.token.transactionIdentifier.nonEmpty {
            collected[ApplePayPlugin.Collected.fingerprint] = .string(fingerprint)
        }
        if let network = ApplePayNetworkMapper.selectedNetwork(for: payment.token.paymentMethod.network) {
            collected[ApplePayPlugin.Collected.network] = .string(network)
        }

        host.setCollected(collected)
        host.setFulfilled(true)
        authorized = true

        // The sheet is told the authorization succeeded — that is about Apple's UI, not the
        // payment. The payment happens at /validate, which the merchant submits next.
        completion(PKPaymentAuthorizationResult(status: .success, errors: nil))
    }

    public func paymentAuthorizationControllerDidFinish(_ controller: PKPaymentAuthorizationController) {
        controller.dismiss { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.controller = nil
                if self.authorized {
                    self.resume(.success(()))
                } else {
                    self.host.setFulfilled(false)
                    self.resume(.failure(PartnerUIError("the shopper dismissed the Apple Pay sheet")))
                }
            }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
