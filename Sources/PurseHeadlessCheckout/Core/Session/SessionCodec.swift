// Web: packages/headless-checkout `setSession(widgetData: string)` base64 decode
// Same: same blob.
// Differs: nothing.

import Foundation

/// Decodes the base64-encoded `widget.data` blob handed to the app by the merchant backend.
public enum SessionCodec {

    /// - Throws: ``PurseSessionError/sessionMalformed(_:)`` if `widgetData` is not valid
    ///   base64/JSON, or the decoded session fails the checks in ``LegacyPaymentSessionParser``.
    public static func decode(_ widgetData: String) throws -> PurseSessionParams {
        guard let data = Data(base64Encoded: widgetData) else {
            throw PurseSessionError.sessionMalformed("could not base64-decode widget data")
        }

        let json: JSONValue
        do {
            json = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw PurseSessionError.sessionMalformed("could not parse widget data as JSON: \(error)")
        }

        guard let paymentSessionNode = json["payment_session"] else {
            throw PurseSessionError.sessionMalformed("payment_session is missing from widget data")
        }

        guard let environment = PurseEnvironment.fromWire(json["environment"]?.stringValue) else {
            throw PurseSessionError.sessionMalformed(
                "unknown or missing environment: \(json["environment"]?.stringValue ?? "nil")"
            )
        }

        return PurseSessionParams(
            apiKey: json["api_key"]?.stringValue ?? "",
            apiURL: json["api_url"]?.stringValue ?? "",
            environment: environment,
            entityId: json["entity_id"]?.stringValue ?? "",
            paymentSession: try LegacyPaymentSessionParser.parse(paymentSessionNode),
            walletSession: parseWalletSession(json["wallet_session"])
        )
    }

    /// A `wallet_session` missing its id or owner reference grants nothing, so it is dropped rather
    /// than half-built — matching Android.
    private static func parseWalletSession(_ json: JSONValue?) -> WalletSessionParams? {
        guard let json,
              let sessionId = json["session_id"]?.stringValue,
              let ownerReference = json["owner_reference"]?.stringValue
        else { return nil }

        return WalletSessionParams(
            sessionId: sessionId,
            ownerReference: ownerReference,
            merchant: json["merchant"]?.stringValue ?? "",
            expirationDate: json["expiration_date"]?.stringValue
        )
    }
}
