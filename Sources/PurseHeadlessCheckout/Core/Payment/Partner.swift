// Web: packages/sdk/src/types.ts (`Partner` union)
// Same: known wire values.
// Differs: enum with `.other(String)`. Android needs a `by lazy` list to dodge a sealed-object init-order NPE; a Swift enum has no such hazard, so the lookup is a plain switch.

import Foundation

/// A PSP — or, for ``Partner/purse``, Purse's own vault — behind a `protocols` entry. Web's
/// `Partner` union has ~38 members; only the ones this SDK targets get a named case.
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
