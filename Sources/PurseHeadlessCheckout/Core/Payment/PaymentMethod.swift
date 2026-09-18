// Web: packages/sdk/src/types.ts (`Method` union)
// Same: known wire values.
// Differs: named `PaymentMethod` — Foundation re-exports Objective-C's `Method` typedef, making a bare `Method` ambiguous and unqualifiable. `applePay` replaces Android's `googlePay`.

import Foundation

/// A payment method under a ``Partner``. Unknown values round-trip through
/// ``PaymentMethod/other(_:)`` rather than being dropped.
public enum PaymentMethod: Sendable, Hashable {
    case creditCard
    /// Not a rename of Android's `googlepay`: different wire value, different integration.
    case applePay
    /// Classic PayPal — distinct from ``PaymentMethod/bnpl`` ("Pay Later").
    case wallet
    case giftCard
    case bnpl
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

    public static func fromWire(_ value: String) -> PaymentMethod {
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
