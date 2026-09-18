// Web: none — web identifies a method by its `(partner, method)` pair inline.
// Same: n/a.
// Differs: a named pair, so an option like `disabledMethods` reads as what it is.

import Foundation

/// The `(partner, method)` pair every plugin is keyed on.
public struct MethodKey: Sendable, Hashable {
    public let partner: Partner
    public let method: PaymentMethod

    public init(partner: Partner, method: PaymentMethod) {
        self.partner = partner
        self.method = method
    }

    /// The item id the checkout gives this method (`"paypal-wallet"`).
    public var id: String { "\(partner.wireValue)-\(method.wireValue)" }

    /// Resolves wire names to their cases, so the key equals what the session decodes to —
    /// `MethodKey(.other("purse"), …)` would not.
    public static func of(partner: String, method: String) -> MethodKey {
        MethodKey(partner: .fromWire(partner), method: .fromWire(method))
    }
}
