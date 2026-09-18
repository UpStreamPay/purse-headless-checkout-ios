// Web: packages/headless-checkout payment-element events.
// Same: one contract for every method.
// Differs: a protocol with defaulted members instead of an event emitter.

import Foundation

/// What every payment surface reports on. Every member is defaulted: implement only what your
/// screen reacts to.
@MainActor
public protocol PaymentElementListener: AnyObject {

    /// Gate your Pay button on this. Self-submitting methods gate themselves.
    func onReady(_ ready: Bool)

    func onOutcome(_ outcome: PaymentOutcome)

    /// A 3-D Secure / PSP page is being opened (informational).
    func onRequiresAction()

    /// This payment's `payment_id`, when the flow could read one. Informational only.
    func onPaymentId(_ paymentId: String)
}

public extension PaymentElementListener {
    func onReady(_ ready: Bool) {}
    func onOutcome(_ outcome: PaymentOutcome) {}
    func onRequiresAction() {}
    func onPaymentId(_ paymentId: String) {}
}
