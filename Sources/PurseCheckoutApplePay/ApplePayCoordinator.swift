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
    /// The amount `/init` created the order for, captured at `prepare()`.
    private var preparedAmount: Decimal?
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
            fallbackMerchantName: configuration.merchantName
        )
        preparedAmount = context.amount
    }

    /// Present the sheet and wait for the shopper. On success the authorized token is stashed on
    /// the checkout, ready for the next submit.
    public func present() async throws {
        guard let request, let preparedAmount else {
            throw PartnerUIError("call prepare() before present() — the sheet has no configuration yet")
        }
        // PassKit presents one sheet at a time; a second call would overwrite the continuation and
        // strand the first caller for the life of the process.
        guard pending == nil else {
            throw PartnerUIError("an Apple Pay sheet is already open")
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
                amount: NSDecimalNumber(decimal: preparedAmount)
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

// PassKit does not document which queue it calls its delegate on, and the whole conformance
// inherits `@MainActor` from the class while mutating `pending`, `authorized` and `controller`.
extension ApplePayCoordinator: PKPaymentAuthorizationControllerDelegate {

    public nonisolated func paymentAuthorizationController(
        _ controller: PKPaymentAuthorizationController,
        didAuthorizePayment payment: PKPayment,
        handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
    ) {
        // `PKPayment` is not `Sendable`; these are. Read them here, before crossing.
        let paymentData = payment.token.paymentData
        let transactionIdentifier = payment.token.transactionIdentifier
        let network = payment.token.paymentMethod.network
        let handler = PassKitHandler(completion)

        Task { @MainActor in
            self.finishAuthorization(
                paymentData: paymentData,
                transactionIdentifier: transactionIdentifier,
                network: network,
                handler: handler
            )
        }
    }

    private func finishAuthorization(
        paymentData: Data,
        transactionIdentifier: String,
        network: PKPaymentNetwork?,
        handler: PassKitHandler
    ) {
        guard let session = ApplePayTokenEnvelope.session(
            for: variant,
            paymentData: paymentData,
            productId: request?.productId
        ) else {
            handler.callAsFunction(PKPaymentAuthorizationResult(status: .failure, errors: nil))
            resume(.failure(PartnerUIError("the Apple Pay token could not be read")))
            return
        }

        var collected: [String: JSONValue] = [ApplePayPlugin.Collected.session: .string(session)]
        if let fingerprint = transactionIdentifier.nonEmpty {
            collected[ApplePayPlugin.Collected.fingerprint] = .string(fingerprint)
        }
        if let mapped = ApplePayNetworkMapper.selectedNetwork(for: network) {
            collected[ApplePayPlugin.Collected.network] = .string(mapped)
        }

        host.setCollected(collected)
        host.setFulfilled(true)
        // The tap *is* the shopper choosing this method — `PluginHost.setAsPrimary`'s own contract
        // for a self-submitting flow, and what Android's `selectAndCapture` does.
        do {
            try host.setAsPrimary()
        } catch {
            handler.callAsFunction(PKPaymentAuthorizationResult(status: .failure, errors: nil))
            resume(.failure(error))
            return
        }
        authorized = true

        // The sheet is told the authorization succeeded — that is about Apple's UI, not the
        // payment. The payment happens at /validate, which the merchant submits next.
        handler.callAsFunction(PKPaymentAuthorizationResult(status: .success, errors: nil))
    }

    public nonisolated func paymentAuthorizationControllerDidFinish(_ controller: PKPaymentAuthorizationController) {
        Task { @MainActor in
            await self.dismissAndResume()
        }
    }

    private func dismissAndResume() async {
        await controller?.dismiss()
        controller = nil
        if authorized {
            resume(.success(()))
        } else {
            host.setFulfilled(false)
            resume(.failure(PartnerUIError("the shopper dismissed the Apple Pay sheet")))
        }
    }
}

/// PassKit's authorization handler, carried across the hop to the main actor.
private struct PassKitHandler: @unchecked Sendable {
    private let completion: (PKPaymentAuthorizationResult) -> Void

    init(_ completion: @escaping (PKPaymentAuthorizationResult) -> Void) {
        self.completion = completion
    }

    func callAsFunction(_ result: PKPaymentAuthorizationResult) {
        completion(result)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
