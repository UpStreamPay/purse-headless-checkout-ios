// Web: packages/partner-ui/src/plugins/partners/klarna-installments/index.ts
// Same: /init → widget (client token) → shopper interacts → /validate → Klarna's own authorize() only after /validate succeeds. One submit therefore both pays and opens Klarna's step.
// Differs: native `KlarnaPaymentView` instead of the Klarna JS SDK; `loadPaymentReview()` is never called (US-only API); the host app supplies its own return URL — see `returnURL` below.

import Foundation
import KlarnaCore
import KlarnaPayments
import PurseHeadlessCheckout
import UIKit

/// Klarna's interactive half: ``prepare(into:returnURL:)`` runs `/init` and inflates the native
/// widget into a container view, waiting for it to finish loading;
/// ``KlarnaPlugin/postValidation(_:context:)`` then calls the widget's `authorize()` through the
@MainActor
public final class KlarnaCoordinator: NSObject {

    private let host: any PluginHost
    private var view: KlarnaPaymentView?
    private var pendingReady: CheckedContinuation<Void, any Error>?
    private var pendingAuthorize: CheckedContinuation<Bool, any Error>?

    public init(host: any PluginHost) {
        self.host = host
    }

    /// `/init` for a client token, inflate the widget into `container`, and wait for it to finish
    /// loading. On success the step id and an authorize token are stashed on the checkout, ready
    /// for the next submit.
    public func prepare(into container: UIView, returnURL: URL) async throws {
        let context = host.buildContext()
        let initResponse = try await context.api.initPayment(
            KlarnaRequestBuilder.initPayload(amount: context.amount, partner: context.partner)
        )
        let config = try KlarnaRequestBuilder.parseInitConfig(initResponse)
        let stepId = KlarnaRequestBuilder.parseStepId(initResponse)

        let paymentView = KlarnaPaymentView(
            category: KlarnaRequestBuilder.paymentMethodCategory,
            returnUrl: returnURL,
            eventListener: self
        )
        container.subviews.forEach { $0.removeFromSuperview() }
        paymentView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(paymentView)
        NSLayoutConstraint.activate([
            paymentView.topAnchor.constraint(equalTo: container.topAnchor),
            paymentView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            paymentView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            paymentView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        view = paymentView

        let token = UUID().uuidString
        await KlarnaAuthorizationRegistry.shared.register(token: token) { [weak self] in
            guard let self else {
                throw PartnerUIError("the Klarna widget was released before authorization")
            }
            return try await self.authorizeWidget()
        }

        // One widget load at a time; a second `prepare()` would overwrite this continuation and
        // strand the first caller.
        guard pendingReady == nil else {
            throw PartnerUIError("a Klarna widget is already being prepared")
        }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                pendingReady = continuation
                paymentView.initialize(clientToken: config.clientToken)
            }
        } catch {
            // The registration above happens before the widget is known to work; drop it rather
            // than leave a closure keyed by a token nothing will ever present.
            await KlarnaAuthorizationRegistry.shared.remove(token)
            throw error
        }

        host.setCollected([
            KlarnaPlugin.Collected.stepId: stepId.map { .number(String($0)) } ?? .null,
            KlarnaPlugin.Collected.authorizeToken: .string(token)
        ])
        host.setFulfilled(true)
    }

    private func authorizeWidget() async throws -> Bool {
        guard let view else {
            throw PartnerUIError("call prepare() before authorizing — the widget has no client token yet")
        }
        guard pendingAuthorize == nil else {
            throw PartnerUIError("a Klarna authorization is already in progress")
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
            pendingAuthorize = continuation
            view.authorize(autoFinalize: true)
        }
    }

    private func resumeReady(_ result: Result<Void, any Error>) {
        pendingReady?.resume(with: result)
        pendingReady = nil
    }

    private func resumeAuthorize(_ result: Result<Bool, any Error>) {
        pendingAuthorize?.resume(with: result)
        pendingAuthorize = nil
    }
}

extension KlarnaCoordinator: KlarnaPaymentEventListener {

    // Klarna's own interface documents no delivery thread for these callbacks, and unlike Secure
    // Fields' source, there is no way to read the binary's actual behavior — hop explicitly rather
    // than assume, the same rule PayPal's and Apple Pay's bridges follow.

    public nonisolated func klarnaInitialized(paymentView: KlarnaPaymentView) {
        Task { @MainActor in paymentView.load(jsonData: nil) }
    }

    /// The "ready" signal: the widget rendered whatever the session offers.
    public nonisolated func klarnaLoaded(paymentView: KlarnaPaymentView) {
        Task { @MainActor in self.resumeReady(.success(())) }
    }

    public nonisolated func klarnaLoadedPaymentReview(paymentView: KlarnaPaymentView) {}

    public nonisolated func klarnaAuthorized(
        paymentView: KlarnaPaymentView,
        approved: Bool,
        authToken: String?,
        finalizeRequired: Bool
    ) {
        Task { @MainActor in
            if finalizeRequired {
                paymentView.finalise(jsonData: nil)
                return
            }
            self.resumeAuthorize(.success(approved))
        }
    }

    public nonisolated func klarnaReauthorized(paymentView: KlarnaPaymentView, approved: Bool, authToken: String?) {}

    public nonisolated func klarnaFinalized(paymentView: KlarnaPaymentView, approved: Bool, authToken: String?) {
        Task { @MainActor in self.resumeAuthorize(.success(approved)) }
    }

    public nonisolated func klarnaResized(paymentView: KlarnaPaymentView, to newHeight: CGFloat) {}

    public nonisolated func klarnaFailed(inPaymentView paymentView: KlarnaPaymentView, withError error: KlarnaPaymentError) {
        // KlarnaError is a plain NSObject with no Sendable annotation — take only what's needed
        // before crossing to the main actor.
        let message = error.message
        Task { @MainActor in
            if let pending = self.pendingAuthorize {
                self.pendingAuthorize = nil
                pending.resume(throwing: PartnerUIError("Klarna authorization failed: \(message)"))
            } else if let pending = self.pendingReady {
                self.pendingReady = nil
                pending.resume(throwing: PartnerUIError("Klarna widget failed to load: \(message)"))
            } else {
                // No pending call to fail — the widget is already up. Clear fulfilment so the
                // merchant's UI reflects that this item can no longer be submitted as-is.
                self.host.setFulfilled(false)
            }
        }
    }
}
