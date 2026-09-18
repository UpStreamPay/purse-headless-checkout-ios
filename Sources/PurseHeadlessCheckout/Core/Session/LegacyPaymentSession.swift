// Web: packages/model `LegacyPaymentSession`
// Same: same fields.
// Differs: typed `Partner` / `PaymentMethod` keys.

import Foundation

/// The `payment_session` object decoded from `widget.data`.
public struct LegacyPaymentSession: Sendable, Equatable {
    public let id: String
    public let amount: Decimal?
    public let informationRequest: Bool?
    public let currencyCode: String
    public let expirationDate: Date
    public let success: String?
    public let failure: String?
    public let redirection: String?
    public let protocols: [Partner: [PaymentMethod: MethodEntry]]
    public let vault: SessionVault?

    public init(
        id: String,
        amount: Decimal?,
        informationRequest: Bool?,
        currencyCode: String,
        expirationDate: Date,
        success: String?,
        failure: String?,
        redirection: String?,
        protocols: [Partner: [PaymentMethod: MethodEntry]],
        vault: SessionVault?
    ) {
        self.id = id
        self.amount = amount
        self.informationRequest = informationRequest
        self.currencyCode = currencyCode
        self.expirationDate = expirationDate
        self.success = success
        self.failure = failure
        self.redirection = redirection
        self.protocols = protocols
        self.vault = vault
    }
}

public struct MethodEntry: Sendable, Equatable {
    public let configurations: MethodConfiguration
    public let integratedTokens: [IntegratedToken]

    public init(configurations: MethodConfiguration, integratedTokens: [IntegratedToken] = []) {
        self.configurations = configurations
        self.integratedTokens = integratedTokens
    }
}
