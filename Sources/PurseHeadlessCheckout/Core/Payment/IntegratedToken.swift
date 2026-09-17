// Web: packages/model `integrated_tokens[]`
// Same: same fields, incl. `pin_code` for saved gift cards.
// Differs: nothing.

import Foundation

/// A saved instrument under `protocols.{partner}.{method}.integrated_tokens[]`.
public struct IntegratedToken: Sendable, Equatable {
    public let id: String
    /// What `/validate` pays with (`payment_data.token`).
    public let value: String
    public let uniquenessToken: String?
    /// Stored security code (gift cards). With ``uniquenessToken`` it re-initialises a saved
    /// secondary token's balance.
    public let pinCode: String?
    public let expirationDate: String?
    public let favorite: Bool
    public let name: String?
    public let source: TokenSource
    public let createdAt: String?
    public let brandName: String?
    public let displayToken: String?
    public let holderName: String?
    public let maskedPAN: String?
    /// `network_token.available` — pairs with `settings.network_token` for the no-CVV gate.
    public let networkTokenAvailable: Bool

    public init(
        id: String,
        value: String,
        uniquenessToken: String?,
        pinCode: String? = nil,
        expirationDate: String?,
        favorite: Bool,
        name: String?,
        source: TokenSource,
        createdAt: String?,
        brandName: String?,
        displayToken: String?,
        holderName: String?,
        maskedPAN: String?,
        networkTokenAvailable: Bool
    ) {
        self.id = id
        self.value = value
        self.uniquenessToken = uniquenessToken
        self.pinCode = pinCode
        self.expirationDate = expirationDate
        self.favorite = favorite
        self.name = name
        self.source = source
        self.createdAt = createdAt
        self.brandName = brandName
        self.displayToken = displayToken
        self.holderName = holderName
        self.maskedPAN = maskedPAN
        self.networkTokenAvailable = networkTokenAvailable
    }
}

/// Web's `IntegratedToken.source`.
public enum TokenSource: String, Sendable, CaseIterable {
    case merchant = "MERCHANT"
    case sharedWallet = "SHARED_WALLET"

    public var wireValue: String { rawValue }

    public static func fromWire(_ value: String?) -> TokenSource {
        guard let value, let source = TokenSource(rawValue: value) else { return .merchant }
        return source
    }
}
