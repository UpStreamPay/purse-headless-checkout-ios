// Web: packages/sdk/src/types.ts (`Partner` union)
// Same: known wire values.
// Differs: enum with `.other(String)`; a plain switch, since Swift has none of the sealed-object init-order hazard Android's `by lazy` list works around.

import Foundation

/// A PSP behind a `protocols` entry. Web's `Partner` union has ~38 members; only the ones this SDK
/// targets get a named case.
public enum Partner: Sendable, Hashable {
    /// Purse's own card vault.
    case purse
    case aci
    case adyen
    case paypal
    case illicado
    case klarna
    case other(String)

    public var wireValue: String {
        switch self {
        case .purse: "purse"
        case .aci: "aci"
        case .adyen: "adyen"
        case .paypal: "paypal"
        case .illicado: "illicado"
        case .klarna: "klarna"
        case let .other(value): value
        }
    }

    public static func fromWire(_ value: String) -> Partner {
        switch value {
        case "purse": .purse
        case "aci": .aci
        case "adyen": .adyen
        case "paypal": .paypal
        case "illicado": .illicado
        case "klarna": .klarna
        default: .other(value)
        }
    }
}
