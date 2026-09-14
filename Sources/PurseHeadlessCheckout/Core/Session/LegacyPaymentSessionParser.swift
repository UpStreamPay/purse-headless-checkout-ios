// Web: packages/model session decode
// Same: same JSON paths.
// Differs: hand-written parser over `JSONValue` instead of org.json.

import Foundation

/// Parses `payment_session` into ``LegacyPaymentSession``. The only structural validation performed
/// — `id` and `expiration_date` must be present — mirrors web's `checkSessionFormat` intentionally.
enum LegacyPaymentSessionParser {

    static func parse(_ json: JSONValue) throws -> LegacyPaymentSession {
        guard let id = json["id"]?.stringValue else {
            throw PurseSessionError.sessionMalformed("id is missing from the session")
        }

        guard let expirationDateRaw = json["expiration_date"]?.stringValue else {
            throw PurseSessionError.sessionMalformed("expiration_date is missing from the session")
        }
        guard let expirationDate = ISO8601Date.parse(expirationDateRaw) else {
            throw PurseSessionError.sessionMalformed(
                "expiration_date is not a valid ISO-8601 instant: \(expirationDateRaw)"
            )
        }

        return LegacyPaymentSession(
            id: id,
            amount: json["amount"]?.decimalValue,
            informationRequest: json["information_request"]?.boolValue,
            currencyCode: json["currency_code"]?.stringValue ?? "",
            expirationDate: expirationDate,
            success: json["success"]?.stringValue,
            failure: json["failure"]?.stringValue,
            redirection: json["redirection"]?.stringValue,
            protocols: parseProtocols(json["protocols"]),
            vault: json["vault"].map(parseSessionVault)
        )
    }

    private static func parseProtocols(_ json: JSONValue?) -> [Partner: [Method: MethodEntry]] {
        guard let partners = json?.objectValue else { return [:] }

        var result: [Partner: [Method: MethodEntry]] = [:]
        for (partnerKey, methodsNode) in partners {
            guard let methodsObject = methodsNode.objectValue else { continue }

            var methods: [Method: MethodEntry] = [:]
            for (methodKey, entryNode) in methodsObject {
                guard let configNode = entryNode["configurations"] else { continue }
                methods[.fromWire(methodKey)] = MethodEntry(
                    configurations: parseMethodConfiguration(configNode),
                    integratedTokens: parseIntegratedTokens(entryNode["integrated_tokens"])
                )
            }
            result[.fromWire(partnerKey)] = methods
        }
        return result
    }

    private static func parseMethodConfiguration(_ json: JSONValue) -> MethodConfiguration {
        let vault = json["vault"].map { node in
            VaultInfo(
                supportedBrands: (node["supported_brands"]?.arrayValue ?? [])
                    .compactMap(\.stringValue)
                    .map(CardBrand.fromWire),
                vendor: .fromWire(node["vendor"]?.stringValue),
                tokenScope: node["token_scope"]?.stringValue,
                externalThreeDSEnabled: node["external_three_ds_enabled"]?.boolValue ?? false
            )
        }

        let settingsNode = json["settings"]
        let merchantSpecifics = settingsNode?["merchant_specifics"]
        let settings = MethodSettings(
            registrationMode: .fromWire(settingsNode?["registration_mode"]?.stringValue),
            // Optional on purpose — web's resolveSaveTokenMode treats an explicit `false`
            // differently from an absent value.
            saveToken: settingsNode?["save_token"]?.boolValue,
            saveTokenMode: settingsNode?["save_token_mode"]?.stringValue,
            directDebit: settingsNode?["direct_debit"]?.boolValue ?? false,
            paymentMinAmount: settingsNode?["payment_min_amount"]?.decimalValue,
            paymentMaxAmount: settingsNode?["payment_max_amount"]?.decimalValue,
            usagePerSessionLimit: settingsNode?["usage_per_session_limit"]?.intValue,
            integrationMode: .fromWire(merchantSpecifics?["integration_mode"]?.stringValue),
            merchantClientId: merchantSpecifics?["client_id"]?.stringValue,
            payTokenNoCVV: merchantSpecifics?["pay_token_no_cvv"]?.boolValue ?? false,
            networkToken: settingsNode?["network_token"]?.boolValue ?? false
        )

        return MethodConfiguration(
            stable: json["stable"]?.boolValue ?? false,
            template: json["template"]?.stringValue,
            labels: (json["labels"]?.arrayValue ?? []).compactMap(\.stringValue),
            position: json["position"]?.intValue,
            vault: vault,
            settings: settings
        )
    }

    private static func parseIntegratedTokens(_ json: JSONValue?) -> [IntegratedToken] {
        guard let nodes = json?.arrayValue else { return [] }

        return nodes.compactMap { node in
            // A token without an id or a value cannot be paid with — skip it rather than fail the
            // whole session decode, matching Android.
            guard let id = node["id"]?.stringValue, let value = node["value"]?.stringValue else { return nil }
            let description = node["description"]
            return IntegratedToken(
                id: id,
                value: value,
                uniquenessToken: node["uniqueness_token"]?.stringValue,
                pinCode: node["pin_code"]?.stringValue,
                expirationDate: node["expiration_date"]?.stringValue,
                favorite: node["favorite"]?.boolValue ?? false,
                name: node["name"]?.stringValue,
                source: .fromWire(node["source"]?.stringValue),
                createdAt: node["created_at"]?.stringValue,
                brandName: description?["brand_name"]?.stringValue,
                displayToken: description?["display_token"]?.stringValue,
                holderName: description?["holder_name"]?.stringValue,
                maskedPAN: description?["masked_pan"]?.stringValue,
                networkTokenAvailable: node["network_token"]?["available"]?.boolValue ?? false
            )
        }
    }

    private static func parseSessionVault(_ json: JSONValue) -> SessionVault {
        let vendorFrontData = json["vendor_front_data"]
        return SessionVault(
            vendorFrontData: VendorFrontData(
                purse: vendorFrontData?["purse"]?["tenant_id"]?.stringValue.map(PurseVaultInfo.init),
                pciProxy: vendorFrontData?["pci_proxy"]?["merchant_id"]?.stringValue.map(PCIProxyVaultInfo.init)
            )
        )
    }
}

/// ISO-8601 instants as the Payment API writes them. `ISO8601DateFormatter` is not one formatter
/// but two: the API sends fractional seconds on some fields and not others, and a formatter
/// configured for one rejects the other outright.
enum ISO8601Date {
    static func parse(_ value: String) -> Date? {
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractionalSeconds.date(from: value) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}
