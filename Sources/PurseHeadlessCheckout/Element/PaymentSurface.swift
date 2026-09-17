// Web: packages/partner-ui `appendTo` — a plugin renders into a container the host hands it.
// Same: a plugin is both a protocol and something rendered.
// Differs: Android returns a `@Composable`; here a `UIView` factory, the only currency the partner halves share (Secure Fields returns `[UIView]`, Klarna wants a container, PassKit and PayPal ship buttons).

import Foundation
import UIKit

/// What one rendered method looks like to a ``PaymentElement``. A ``PartnerModule`` builds these.
@MainActor
public struct PaymentSurface {

    /// Web's `hasUI()`. `false` for a no-CVV saved card and a redirection method.
    public let hasUI: Bool

    /// Apple Pay and PayPal pay from their own button. Do not offer a Pay button for one of these.
    public let selfSubmitting: Bool

    let makeView: () -> UIView?

    /// The partner's own setup — Klarna's widget load, Apple Pay's `/init`. Reports on the listener.
    let prepare: () async -> Void

    /// The native step, then `/validate`. Reports every end on the listener; never throws.
    let submit: () async -> Void

    public init(
        hasUI: Bool,
        selfSubmitting: Bool,
        makeView: @escaping () -> UIView?,
        prepare: @escaping () async -> Void = {},
        submit: @escaping () async -> Void
    ) {
        self.hasUI = hasUI
        self.selfSubmitting = selfSubmitting
        self.makeView = makeView
        self.prepare = prepare
        self.submit = submit
    }

    /// Nothing to show — a redirection method, or a saved instrument that needs no form.
    public static func headless(
        prepare: @escaping () async -> Void = {},
        submit: @escaping () async -> Void
    ) -> PaymentSurface {
        PaymentSurface(hasUI: false, selfSubmitting: false, makeView: { nil }, prepare: prepare, submit: submit)
    }
}

/// What a ``PartnerModule`` needs to render one payment item.
@MainActor
public struct SurfaceRequest {

    /// This item's checkout seam. One per element, so a coordinator may be built against it.
    public let host: any PluginHost

    /// `true` when the item is a saved instrument rather than a fresh method.
    public let isToken: Bool

    /// `"{itemId}:{generation}"` — changes when the element must rebuild.
    public let key: String

    public let listener: any PaymentElementListener

    /// Klarna's app-return deep link. `nil` means none was given; say so on the listener rather
    /// than guess — iOS has no `applicationId` to synthesize one from.
    public let appReturnURL: URL?

    /// Where a redirect is presented. `nil` means the host follows redirects itself.
    public let redirectPresenter: (any RedirectPresenter)?

    /// See ``ElementFlow``.
    let capture: () async -> Void

    init(
        host: any PluginHost,
        isToken: Bool,
        key: String,
        listener: any PaymentElementListener,
        appReturnURL: URL?,
        redirectPresenter: (any RedirectPresenter)?,
        capture: @escaping () async -> Void
    ) {
        self.host = host
        self.isToken = isToken
        self.key = key
        self.listener = listener
        self.appReturnURL = appReturnURL
        self.redirectPresenter = redirectPresenter
        self.capture = capture
    }

    /// `setAsPrimary()` then ``captureNow()``, for self-submitting flows. A refusal ends the attempt
    /// here rather than escaping into a partner SDK's completion handler that would not catch it.
    public func selectAndCapture() async {
        do {
            try host.setAsPrimary()
        } catch {
            listener.onOutcome(.failed(error.asPurseError()))
            return
        }
        await capture()
    }

    /// `/validate` for a surface the host already made primary.
    public func captureNow() async {
        await capture()
    }
}

public extension Error {
    /// Public because each partner product builds its own surface and reports its own failures.
    func asPurseError() -> any PurseError {
        (self as? any PurseError) ?? PartnerUIError(localizedDescription, underlying: self)
    }
}
