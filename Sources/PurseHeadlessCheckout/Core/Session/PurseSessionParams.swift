// Web: packages/headless-checkout `PurseHeadlessCheckoutV2Params` (decoded `widget.data`)
// Same: api_key, api_url, environment, entity_id, payment_session, wallet_session.
// Differs: nothing.

import Foundation

/// The decoded `widget.data` payload.
public struct PurseSessionParams: Sendable, Equatable {
    public let apiKey: String
    public let apiURL: String
    public let environment: PurseEnvironment
    public let entityId: String
    public let paymentSession: LegacyPaymentSession
    /// Present when the merchant backend attached a `wallet_session` (saved-card wallet access).
    public let walletSession: WalletSessionParams?

    public init(
        apiKey: String,
        apiURL: String,
        environment: PurseEnvironment,
        entityId: String,
        paymentSession: LegacyPaymentSession,
        walletSession: WalletSessionParams? = nil
    ) {
        self.apiKey = apiKey
        self.apiURL = apiURL
        self.environment = environment
        self.entityId = entityId
        self.paymentSession = paymentSession
        self.walletSession = walletSession
    }
}

/// The optional `wallet_session` object from `widget.data` — web sdk's `OnePayWalletSession`.
/// Grants access to the shopper's saved-token wallet (Wallet API v2) for the checkout's lifetime.
public struct WalletSessionParams: Sendable, Equatable {
    public let sessionId: String
    public let ownerReference: String
    /// The merchant id sent as `x-merchant-id` on every Wallet API call.
    public let merchant: String
    public let expirationDate: String?

    public init(sessionId: String, ownerReference: String, merchant: String, expirationDate: String?) {
        self.sessionId = sessionId
        self.ownerReference = ownerReference
        self.merchant = merchant
        self.expirationDate = expirationDate
    }
}
