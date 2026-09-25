// Web: none — on web a plugin holds the checkout context directly.
// Same: what a plugin can ask of the checkout.
// Differs: a protocol implemented by the checkout, so PartnerUI never depends on Checkout.

import Foundation

/// What a coordinator needs from the checkout for one payment item. A coordinator only calls the
/// members its flow uses.
@MainActor
public protocol PluginHost: AnyObject {
    var environment: PurseEnvironment { get }

    /// The session's own return URL, threaded into a 3-D Secure redirect so the web authentication
    /// session recognizes reaching it as completion. Never auto-followed.
    var redirectionReturnURL: String? { get }

    func buildContext() -> PartnerUIContext

    /// Stash what the native step produced (a sheet token, a `/init` step id, a vault token) for the
    /// next submit.
    func setCollected(_ data: [String: JSONValue])

    /// Commit this item as the split's primary. Self-submitting flows call it on approval: the tap
    /// is the shopper choosing the method, and a cancelled sheet leaves the split untouched.
    func setAsPrimary() throws

    /// Whether this item's own form is complete and valid; gates fulfilment.
    func setFulfilled(_ fulfilled: Bool)

    func submitPayment() async throws -> ValidationResult
}

public extension PluginHost {
    /// Android's `PaymentCoordinator.dispatch`: report a ``PluginEvent`` to the checkout.
    func dispatch(_ event: PluginEvent) {
        buildContext().dispatchEvent(event)
    }
}
