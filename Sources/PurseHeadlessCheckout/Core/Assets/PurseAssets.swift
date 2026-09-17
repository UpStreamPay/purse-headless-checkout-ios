// Web: packages/assets (`iconUrl`, `additionalAssets` on payment items)
// Same: same CDN paths per environment, same badge tables.
// Differs: nothing.
// Android: eu.purse.core.assets.PurseAssets

import Foundation

/// Web's `@upstreampay/assets`. URL builders only — loading and rendering the SVGs is the
/// integrator's job, as on Android.
public enum PurseAssets {

    public struct CardSchemeAsset: Sendable, Equatable {
        public let url: String
        public let label: String

        public init(url: String, label: String) {
            self.url = url
            self.label = label
        }
    }

    /// Web's `getCdnBase`.
    public static func cdnBase(_ environment: PurseEnvironment) -> String {
        environment == .production
            ? "https://cdn.purse-secure.com/assets/"
            : "https://cdn.purse-sandbox.com/assets/"
    }

    public static func badgeURL(_ environment: PurseEnvironment, badgeName: String) -> String {
        "\(cdnBase(environment))img/badges/\(badgeName).svg"
    }

    /// Web's `resolveIconUrl`.
    public static func resolveIconURL(
        partner: Partner,
        method: PaymentMethod,
        isSecondary: Bool,
        environment: PurseEnvironment
    ) -> String {
        let name: String
        if let entry = mopBadges[partner.wireValue] {
            name = entry[method.wireValue] ?? entry[defaultKey] ?? defaultPrimary
        } else {
            name = isSecondary ? defaultSecondary : defaultPrimary
        }
        return badgeURL(environment, badgeName: name)
    }

    /// Web's `buildCardSchemeAssets`. A brand with no badge is dropped, not pointed at a 404.
    public static func buildCardSchemeAssets(
        brands: [CardBrand],
        environment: PurseEnvironment
    ) -> [CardSchemeAsset] {
        brands.compactMap { brand in
            guard let entry = cardSchemeBadges[brand] else { return nil }
            return CardSchemeAsset(url: badgeURL(environment, badgeName: entry.badge), label: entry.label)
        }
    }

    private static let defaultKey = "default"
    private static let defaultPrimary = "creditcard"
    private static let defaultSecondary = "giftcard2"

    private static func badge(_ name: String) -> [String: String] { [defaultKey: name] }

    /// A partner whose card rail also fronts Apple Pay and Google Pay.
    private static let xpayCardPartner: [String: String] = [
        "applepay": "applepay",
        "googlepay": "googlepay",
        defaultKey: "creditcard"
    ]

    /// Web's `MOPs_BADGES`, keyed by partner then method wire value (or `default`).
    private static let mopBadges: [String: [String: String]] = [
        "aci": badge("creditcard"),
        "ancv": badge("ancv"),
        "adyen": xpayCardPartner.merging(["bancontact": "bancontact", "ideal": "ideal"]) { _, new in new },
        "alma": badge("alma"),
        "axepta": xpayCardPartner,
        "braintree": badge("paypal"),
        "centralpay": badge("creditcard"),
        "checkout": xpayCardPartner,
        "cofidis": badge("cofidis"),
        "dalenys": badge("creditcard"),
        "easycollect": badge("creditcard"),
        "fintecture": badge("fintecture"),
        "floa": badge("floa"),
        "gocardless": badge("giftcard2"),
        "hipay": badge("creditcard").merging(["mbway": "mbway", "multibanco": "multibanco"]) { _, new in new },
        "illicado": badge("illicado"),
        "easy2play": ["voucher": "voucher", defaultKey: "giftcard2"],
        "ingenico": xpayCardPartner,
        "klarna": badge("klarna"),
        "mercanet": badge("creditcard"),
        "oney": badge("oney"),
        "oneycard": badge("oney"),
        "paybox": badge("creditcard"),
        "payline": badge("creditcard").merging(["mbway": "mbway", "multibanco": "multibanco"]) { _, new in new },
        "paypal": badge("paypal"),
        "payzen": badge("creditcard").merging(["sepa": "sepa"]) { _, new in new },
        "purse": badge("creditcard"),
        "redsys": badge("creditcard"),
        "riverty": badge("riverty"),
        "scalapay": badge("scalapay"),
        "sipsv2": badge("creditcard"),
        "slimpay": badge("slimpay"),
        "sogecommerce": badge("creditcard"),
        "sogenactif": badge("creditcard"),
        "stripe": xpayCardPartner,
        "systempay": badge("creditcard"),
        "worldpay": badge("creditcard"),
        "scellius": badge("sepa"),
        "younited": badge("younited")
    ]

    /// Web's `CARD_SCHEME_BADGES`.
    private static let cardSchemeBadges: [CardBrand: (badge: String, label: String)] = [
        .americanExpress: ("amex", "American Express"),
        .carteBancaire: ("cb", "Cartes Bancaires"),
        .visa: ("visa", "Visa"),
        .mastercard: ("mastercard", "Mastercard"),
        .maestro: ("maestro", "Maestro"),
        .oney: ("oney", "Oney")
    ]
}
