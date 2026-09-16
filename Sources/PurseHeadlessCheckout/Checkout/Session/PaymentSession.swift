// Web: packages/headless-checkout/src/session/payment/payment.ts (session in force)
// Same: id, amount, currency, expiry, vault configuration, means of payment.
// Differs: built once by `PaymentSessionBuilder`.

import Foundation

/// The built session — the raw ``LegacyPaymentSession`` plus the derived, ready-to-consume payment
/// model.
public struct PaymentSession: Sendable, Equatable {
    public let id: String
    public let source: LegacyPaymentSession
    public let amount: Decimal
    /// ``amount`` in integer cents (×100) — the unit the splitter works in.
    public let amountCents: Int64
    public let isInformationRequest: Bool
    public let currency: String
    public let expirationDate: Date
    /// Session-level vault config (`vault.vendor_front_data`) — tenant / merchant ids for capture.
    public let vaultsConfiguration: VendorFrontData?
    public let meansOfPayment: [PaymentItem]
}

/// Where the checkout is in its lifecycle.
public enum SessionState: String, Sendable, CaseIterable {
    /// Usable: methods can be selected and a payment submitted.
    case ready = "READY"
    /// The session's expiry has passed; nothing can be submitted until a fresh session is set.
    case expired = "EXPIRED"
    /// A submit is in flight.
    case submitting = "SUBMITTING"
    /// A `/validate` has answered — the session is spent, whatever the outcome.
    case submitted = "SUBMITTED"
    /// A partner ended the session.
    case terminated = "TERMINATED"
    /// A submit failed in a way that leaves the checkout usable.
    case error = "ERROR"
}
