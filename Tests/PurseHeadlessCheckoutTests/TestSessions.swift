import Foundation
@testable import PurseHeadlessCheckout

/// Session fixtures. Mirrors Android's `eu/purse/core/session/TestSessions.kt`: build the JSON a
/// real backend sends, base64 it, and let the real codec do the work — never construct the model
/// types directly, or the parser is never exercised.
enum TestSessions {

    static func widgetData(
        environment: String = "sandbox",
        apiKey: String = "test-key",
        entityId: String = "entity-1",
        paymentSession: [String: Any] = Self.paymentSession(),
        walletSession: [String: Any]? = nil
    ) -> String {
        var blob: [String: Any] = [
            "api_key": apiKey,
            "api_url": "https://api.purse-sandbox.com",
            "environment": environment,
            "entity_id": entityId,
            "payment_session": paymentSession,
        ]
        if let walletSession {
            blob["wallet_session"] = walletSession
        }
        return encode(blob)
    }

    static func paymentSession(
        id: String = "session-1",
        amount: Any? = 42.50,
        currencyCode: String = "EUR",
        expirationDate: String = "2099-01-01T00:00:00Z",
        protocols: [String: Any] = Self.cardProtocol(),
        vault: [String: Any]? = ["vendor_front_data": ["purse": ["tenant_id": "tenant-1"]]],
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var session: [String: Any] = [
            "id": id,
            "currency_code": currencyCode,
            "expiration_date": expirationDate,
            "protocols": protocols,
        ]
        if let amount { session["amount"] = amount }
        if let vault { session["vault"] = vault }
        session.merge(extra) { _, new in new }
        return session
    }

    /// One Purse-vaulted credit card, the shape every card test starts from.
    static func cardProtocol(
        settings: [String: Any] = [:],
        labels: [String] = [],
        integratedTokens: [[String: Any]] = []
    ) -> [String: Any] {
        var configurations: [String: Any] = [
            "stable": true,
            "labels": labels,
            "vault": [
                "vendor": "purse",
                "supported_brands": ["VISA", "MASTERCARD"],
                "external_three_ds_enabled": false,
            ],
            "settings": settings,
        ]
        if configurations["template"] == nil { configurations.removeValue(forKey: "template") }

        var entry: [String: Any] = ["configurations": configurations]
        if !integratedTokens.isEmpty {
            entry["integrated_tokens"] = integratedTokens
        }
        return ["purse": ["creditcard": entry]]
    }

    static func encode(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return data.base64EncodedString()
    }

    /// Base64 of arbitrary text, for the malformed-input cases.
    static func base64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }
}
