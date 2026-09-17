// Web: packages/model `protocols[partner][method].configurations`
// Same: vault, template, labels, settings / merchant_specifics.
// Differs: nothing.

import Foundation

/// `protocols.{partner}.{method}.configurations`.
public struct MethodConfiguration: Sendable, Equatable {
    public let stable: Bool
    public let template: String?
    public let labels: [String]
    public let position: Int?
    public let vault: VaultInfo?
    public let settings: MethodSettings

    public init(
        stable: Bool,
        template: String?,
        labels: [String],
        position: Int?,
        vault: VaultInfo?,
        settings: MethodSettings
    ) {
        self.stable = stable
        self.template = template
        self.labels = labels
        self.position = position
        self.vault = vault
        self.settings = settings
    }

    /// Secondary iff `labels` contains `"secondary"` — not a `template` or partner check.
    public var isSecondary: Bool { labels.contains(Self.secondaryLabel) }

    public static let secondaryLabel = "secondary"
}

public struct VaultInfo: Sendable, Equatable {
    public let supportedBrands: [CardBrand]
    public let vendor: VaultVendor
    public let tokenScope: String?
    public let externalThreeDSEnabled: Bool

    public init(supportedBrands: [CardBrand], vendor: VaultVendor, tokenScope: String?, externalThreeDSEnabled: Bool) {
        self.supportedBrands = supportedBrands
        self.vendor = vendor
        self.tokenScope = tokenScope
        self.externalThreeDSEnabled = externalThreeDSEnabled
    }
}

public struct MethodSettings: Sendable, Equatable {
    public let registrationMode: RegistrationMode
    /// `save_token` — optional because web distinguishes an explicit `false` from an absent value.
    public let saveToken: Bool?
    public let saveTokenMode: String?
    public let directDebit: Bool
    public let paymentMinAmount: Decimal?
    public let paymentMaxAmount: Decimal?
    public let usagePerSessionLimit: Int?
    public let integrationMode: IntegrationMode?
    /// `merchant_specifics.client_id` — the PSP's client-side SDK id (e.g. PayPal's REST client id).
    public let merchantClientId: String?
    /// `merchant_specifics.pay_token_no_cvv`.
    public let payTokenNoCVV: Bool
    /// `settings.network_token` — the network-token no-CVV path.
    public let networkToken: Bool

    public init(
        registrationMode: RegistrationMode,
        saveToken: Bool?,
        saveTokenMode: String?,
        directDebit: Bool,
        paymentMinAmount: Decimal?,
        paymentMaxAmount: Decimal?,
        usagePerSessionLimit: Int?,
        integrationMode: IntegrationMode?,
        merchantClientId: String? = nil,
        payTokenNoCVV: Bool = false,
        networkToken: Bool = false
    ) {
        self.registrationMode = registrationMode
        self.saveToken = saveToken
        self.saveTokenMode = saveTokenMode
        self.directDebit = directDebit
        self.paymentMinAmount = paymentMinAmount
        self.paymentMaxAmount = paymentMaxAmount
        self.usagePerSessionLimit = usagePerSessionLimit
        self.integrationMode = integrationMode
        self.merchantClientId = merchantClientId
        self.payTokenNoCVV = payTokenNoCVV
        self.networkToken = networkToken
    }
}
