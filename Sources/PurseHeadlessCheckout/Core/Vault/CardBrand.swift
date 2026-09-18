// Web: packages/model card brands (`vault.supported_brands`)
// Same: same wire values.
// Differs: distinct from Secure Fields' own `CardBrand` enum.

import Foundation

/// The session's `vault.supported_brands`. Deliberately distinct from `PurseSecureFields.CardBrand`,
/// whose BIN-lookup vocabulary differs (`AMEX` vs `AMERICAN_EXPRESS`).
public enum CardBrand: String, Sendable, CaseIterable {
    case carteBancaire = "CARTE_BANCAIRE"
    case visa = "VISA"
    case mastercard = "MASTERCARD"
    case americanExpress = "AMERICAN_EXPRESS"
    case maestro = "MAESTRO"
    case dinersClub = "DINERS_CLUB"
    case discover = "DISCOVER"
    case unionPay = "UNIONPAY"
    case jcb = "JCB"
    case oney = "ONEY"
    case unknown = ""

    public var wireValue: String { rawValue }

    public static func fromWire(_ value: String) -> CardBrand {
        CardBrand(rawValue: value) ?? .unknown
    }
}
