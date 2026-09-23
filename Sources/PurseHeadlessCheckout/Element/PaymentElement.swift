// Web: packages/headless-checkout/src/payment-element/payment-element.ts (`getPaymentElement`).
// Same: one element per rendered method or saved token; `hasUI` false for redirection and no-CVV tokens.
// Differs: an object from the checkout, not a Compose `remember` — so keying it is the caller's job.

import Foundation
import UIKit

/// One rendered payment method or saved token. Build it when the shopper *selects* the item, not
/// for every row — building runs the partner's `prepare`, which for Klarna and Apple Pay is a
/// `POST /init`. A redirection method's `/init` runs later, in `preValidation`. For per-field card
/// state, drive a ``CardCoordinator`` instead — see `docs/integration/card-form.md`.
@MainActor
public final class PaymentElement: ObservableObject {

    public let item: PaymentItem

    /// Web's `hasUI()`.
    public let hasUI: Bool

    /// Apple Pay and PayPal pay from their own button; ``submit()`` is a no-op for them.
    public let selfSubmitting: Bool

    /// Gate your Pay button on this.
    @Published public private(set) var isReady = false

    private let surface: PaymentSurface
    /// Held, not just wired: the surface's closures are the only other owner.
    private let listener: ElementListener
    private var inFlight: Task<Void, Never>?
    private var prepared = false

    init(item: PaymentItem, surface: PaymentSurface, listener: ElementListener) {
        self.item = item
        self.hasUI = surface.hasUI
        self.selfSubmitting = surface.selfSubmitting
        self.surface = surface
        self.listener = listener
        listener.onReadyChange = { [weak self] ready in self?.isReady = ready }
    }

    public func makeView() -> UIView? {
        hasUI ? surface.makeView() : nil
    }

    /// Idempotent, so SwiftUI's `.task` re-running it costs nothing. Failures land on the listener.
    public func prepare() async {
        guard !prepared else { return }
        prepared = true
        await surface.prepare()
    }

    /// The native step, then `/validate`. Synchronous — Apple Pay and PayPal drive it from a
    /// `UIControl` action, which cannot await.
    @discardableResult
    public func submit() -> Task<Void, Never> {
        if let inFlight { return inFlight }
        let task = Task { @MainActor [surface] in
            await surface.submit()
            self.inFlight = nil
        }
        inFlight = task
        return task
    }
}

/// The merchant's listener plus a tap on `onReady` driving ``PaymentElement/isReady``. The
/// indirection exists because the surface is built before the element that reads `hasUI` off it.
@MainActor
final class ElementListener: PaymentElementListener {
    private let wrapped: any PaymentElementListener
    var onReadyChange: ((Bool) -> Void)?

    init(_ wrapped: any PaymentElementListener) {
        self.wrapped = wrapped
    }

    func onReady(_ ready: Bool) {
        onReadyChange?(ready)
        wrapped.onReady(ready)
    }

    func onOutcome(_ outcome: PaymentOutcome) { wrapped.onOutcome(outcome) }
    func onRequiresAction() { wrapped.onRequiresAction() }
    func onPaymentId(_ paymentId: String) { wrapped.onPaymentId(paymentId) }
}
