// Web: packages/partner-ui/src/plugins/generics/applepay/{types,partners_specifics,partners/*}.ts
// Same: the payment request is built entirely from /init's plugin_result.logs, per partner.
// Differs: no merchant-validation round trip. Web's `onvalidatemerchant` posts the validationURL back as a second /init; PassKit has no such step — Apple validates in-process against the processing certificate. In-app is simpler than web here.

import Foundation
import PassKit
import PurseHeadlessCheckout

/// What the merchant must supply, because no server can. `merchantIdentifier` has to be listed in
/// the app's `com.apple.developer.in-app-payments` entitlement, which is validated against the
/// app's provisioning profile — so it must exist in the merchant's own Apple Developer account.
public struct ApplePayConfiguration: Sendable {
    public let merchantIdentifier: String
    /// What the shopper reads on the sheet's total line when `/init` names nobody.
    public let merchantName: String

    public init(merchantIdentifier: String, merchantName: String) {
        self.merchantIdentifier = merchantIdentifier
        self.merchantName = merchantName
    }
}

/// The partner-specific shape of an Apple Pay `/init` answer and its authorized token. Purse
/// **forwards** the Apple token; it never decrypts it.
enum ApplePayVariant: Sendable {
    case adyen
    case ingenico
    case `default`

    static func of(_ partner: Partner) -> ApplePayVariant {
        switch partner {
        case .adyen: .adyen
        case .other("ingenico"): .ingenico
        default: .default
        }
    }
}

/// The request fields `/init` supplies. Built per variant; everything here is server-driven.
struct ApplePayRequestConfiguration: Sendable {
    let countryCode: String
    let currencyCode: String
    let merchantName: String
    let merchantCapabilities: PKMerchantCapability
    let supportedNetworks: [PKPaymentNetwork]
    /// Ingenico's Worldline product id, echoed back on the authorized token.
    let productId: String?

    /// Web's `APPLE_PAY_DEFAULT_SUPPORTED_BRANDS`.
    static let defaultNetworks: [PKPaymentNetwork] = [.cartesBancaires, .masterCard, .visa]

    static func from(
        initResponse: JSONValue,
        variant: ApplePayVariant,
        fallbackMerchantName: String
    ) throws -> ApplePayRequestConfiguration {
        guard let logs = initResponse["plugin_result"]?["logs"] else {
            throw PartnerUIError("Apple Pay /init returned no plugin_result.logs to configure the sheet")
        }

        /// A `PKPaymentRequest` with an empty country or currency cannot be presented, and PassKit
        /// does not say why — the sheet just refuses, and `present()`'s diagnosis blames the
        /// entitlement. Failing here names the real cause instead.
        func require(_ value: String?, _ field: String) throws -> String {
            guard let value, !value.isEmpty else {
                throw PartnerUIError("Apple Pay /init did not return \(field); the sheet cannot be presented")
            }
            return value
        }

        switch variant {
        case .ingenico:
            return ApplePayRequestConfiguration(
                countryCode: try require(logs["countryCode"]?.stringValue, "a country code"),
                currencyCode: try require(logs["currencyCode"]?.stringValue, "a currency code"),
                merchantName: logs["merchantName"]?.stringValue?.nonEmpty ?? fallbackMerchantName,
                merchantCapabilities: capabilities(from: logs["merchantCapabilities"]?.stringValue),
                supportedNetworks: Self.defaultNetworks,
                productId: logs["productId"].flatMap { $0.intValue.map(String.init) ?? $0.stringValue }
            )

        case .adyen:
            return ApplePayRequestConfiguration(
                countryCode: try require(logs["country_code"]?.stringValue, "a country code"),
                currencyCode: try require(logs["currency_code"]?.stringValue, "a currency code"),
                merchantName: fallbackMerchantName,
                merchantCapabilities: .threeDSecure,
                supportedNetworks: Self.defaultNetworks,
                productId: nil
            )

        case .default:
            // The default variant nests its configuration inside a JSON *string*.
            let nested = logs["payment_method_configuration"]?.stringValue
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }

            let networks = nested?["brands"]?.arrayValue?
                .compactMap { $0.stringValue.flatMap(ApplePayJSNetworkMapper.network(forJSName:)) }

            return ApplePayRequestConfiguration(
                countryCode: try require(logs["country_code"]?.stringValue, "a country code"),
                currencyCode: try require(logs["currency_code"]?.stringValue, "a currency code"),
                merchantName: nested?["configuration"]?["merchantName"]?.stringValue?.nonEmpty ?? fallbackMerchantName,
                merchantCapabilities: .threeDSecure,
                supportedNetworks: networks?.isEmpty == false ? networks! : Self.defaultNetworks,
                productId: nil
            )
        }
    }

    /// `merchantCapabilities` arrives as a JSON array of Apple Pay JS capability strings.
    private static func capabilities(from json: String?) -> PKMerchantCapability {
        guard let json,
              let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data)
        else { return .threeDSecure }

        var capabilities: PKMerchantCapability = []
        for value in values {
            switch value {
            case "supports3DS": capabilities.insert(.threeDSecure)
            case "supportsCredit": capabilities.insert(.credit)
            case "supportsDebit": capabilities.insert(.debit)
            case "supportsEMV": capabilities.insert(.emv)
            default: break
            }
        }
        // A request with no capabilities is rejected by PassKit, and 3-D Secure is the one every
        // PSP in this catalogue supports.
        return capabilities.isEmpty ? .threeDSecure : capabilities
    }
}

/// Wraps the authorized token in the shape the PSP's API expects.
///
/// The encrypted payload is identical in every case — only the envelope differs.
enum ApplePayTokenEnvelope {
    /// Takes the token's `paymentData` rather than the `PKPaymentToken` itself: `PKPaymentToken` is
    /// not `Sendable`, and the delegate that produces it reads this one value out before hopping to
    /// the main actor. It was the only thing this ever used.
    static func session(for variant: ApplePayVariant, paymentData: Data, productId: String?) -> String? {
        // An empty token is not a payment. Two of the three variants would happily wrap it — adyen
        // base64s it to `""`, ingenico decodes it to `""` — and the PSP answers `BAD_REQUEST /
        // Missing payment method details` a round trip later, naming nothing.
        guard !paymentData.isEmpty else { return nil }

        switch variant {
        case .adyen:
            // Adyen wants the payment data base64-encoded.
            return json([
                "paymentMethod": [
                    "type": "applepay",
                    "applePayToken": paymentData.base64EncodedString(),
                ],
            ])

        case .ingenico:
            var method: [String: Any] = [
                "type": "applepay",
                "applePayToken": String(decoding: paymentData, as: UTF8.self),
            ]
            if let productId { method["productId"] = productId }
            return json(["paymentMethod": method])

        case .default:
            // The default variant forwards Apple's token object as-is.
            guard let object = try? JSONSerialization.jsonObject(with: paymentData) else { return nil }
            return json(object)
        }
    }

    private static func json(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Apple Pay **JS** network name strings (what `/init`'s `brands` array carries, and what web
/// passes straight into `ApplePaySDKConfig.supportedNetworks`) → **native** `PKPaymentNetwork`.
enum ApplePayJSNetworkMapper {
    static func network(forJSName name: String) -> PKPaymentNetwork? {
        switch name {
        case "visa": .visa
        case "masterCard": .masterCard
        case "amex": .amex
        case "cartesBancaires": .cartesBancaires
        case "discover": .discover
        case "jcb": .JCB
        case "maestro": .maestro
        case "privateLabel": .privateLabel
        case "electron": .electron
        case "elo": .elo
        case "interac": .interac
        case "vPay": .vPay
        default: nil
        }
    }
}

/// Apple's network names → the Payment API's vocabulary, as web's `brandMapper` does.
enum ApplePayNetworkMapper {
    static func selectedNetwork(for network: PKPaymentNetwork?) -> String? {
        guard let network else { return nil }
        switch network {
        case .visa: return "VISA"
        case .masterCard: return "MASTERCARD"
        case .amex: return "AMERICAN_EXPRESS"
        case .cartesBancaires: return "CARTE_BANCAIRE"
        case .maestro: return "MAESTRO"
        case .discover: return "DISCOVER"
        case .JCB: return "JCB"
        default: return nil
        }
    }
}
