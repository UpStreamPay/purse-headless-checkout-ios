// Web: packages/sdk/src/types.ts (`Method` union)
// Same: known wire values.
// Differs: enum with `.other(String)`; `applePay` replaces Android's `googlePay`.

import Foundation

/// A payment method under a ``Partner`` in a `protocols` entry. Only the methods this SDK targets
/// get a named case; anything else round-trips through ``Method/other(_:)`` rather than being
/// dropped.
public enum Method: Sendable, Hashable {
    /// Carte Bancaire / generic card payment.
    case creditCard
    /// Apple Pay. The Android SDK's equivalent case is `googlepay`; the wire value differs, and so
    /// does the whole partner integration — this is not a rename of the same thing.
    case applePay
    /// Classic PayPal — distinct from the sibling ``Method/bnpl`` ("Pay Later").
    case wallet
    case giftCard
    case bnpl
    /// Klarna's own pay-later / slice-it method.
    case installments
    case other(String)

    public var wireValue: String {
        switch self {
        case .creditCard: "creditcard"
        case .applePay: "applepay"
        case .wallet: "wallet"
        case .giftCard: "giftcard"
        case .bnpl: "bnpl"
        case .installments: "installments"
        case let .other(value): value
        }
    }

    public static func fromWire(_ value: String) -> Method {
        switch value {
        case "creditcard": .creditCard
        case "applepay": .applePay
        case "wallet": .wallet
        case "giftcard": .giftCard
        case "bnpl": .bnpl
        case "installments": .installments
        default: .other(value)
        }
    }
}
