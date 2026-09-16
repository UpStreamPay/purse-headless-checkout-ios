// Web: packages/headless-checkout/src/session/payment/mops/item-factory (primary / secondary items)
// Same: id `{partner}-{method}`, configuration, disabled state.
// Differs: an enum rather than a sealed class; saved gift cards are `savedSecondaryToken`, not `type: 'token'` mops.

import Foundation

private let simulableLabel = "simulable"

/// One `protocols.{partner}.{method}` entry turned into a means of payment. ``id`` follows web's
/// `"{partner}-{method}"` convention (e.g. `"purse-creditcard"`), except for tokens, which carry
/// their own wallet id.
public enum PaymentItem: Sendable, Equatable {
    case primaryMethod(PrimaryMethod)
    case secondaryMethod(SecondaryMethod)
    case paymentToken(PaymentToken)
    case savedSecondaryToken(SavedSecondaryToken)

    public var id: String {
        switch self {
        case let .primaryMethod(item): item.id
        case let .secondaryMethod(item): item.id
        case let .paymentToken(item): item.id
        case let .savedSecondaryToken(item): item.id
        }
    }

    public var partner: Partner {
        switch self {
        case let .primaryMethod(item): item.partner
        case let .secondaryMethod(item): item.partner
        case let .paymentToken(item): item.partner
        case let .savedSecondaryToken(item): item.partner
        }
    }

    public var method: Method {
        switch self {
        case let .primaryMethod(item): item.method
        case let .secondaryMethod(item): item.method
        case let .paymentToken(item): item.method
        case let .savedSecondaryToken(item): item.method
        }
    }

    public var configuration: MethodConfiguration {
        switch self {
        case let .primaryMethod(item): item.configuration
        case let .secondaryMethod(item): item.configuration
        case let .paymentToken(item): item.configuration
        case let .savedSecondaryToken(item): item.configuration
        }
    }

    public var disabled: DisabledState? {
        switch self {
        case let .primaryMethod(item): item.disabled
        case let .secondaryMethod(item): item.disabled
        case let .paymentToken(item): item.disabled
        case let .savedSecondaryToken(item): item.disabled
        }
    }

    public var isSecondary: Bool {
        switch self {
        case .primaryMethod, .paymentToken: false
        case .secondaryMethod, .savedSecondaryToken: true
        }
    }

    public var minAmount: Decimal? { configuration.settings.paymentMinAmount }
    public var maxAmount: Decimal? { configuration.settings.paymentMaxAmount }

    /// A copy with a new disabled state — items are immutable, and recomputing availability
    /// produces a fresh list.
    public func withDisabled(_ disabled: DisabledState?) -> PaymentItem {
        switch self {
        case var .primaryMethod(item):
            item.disabled = disabled
            return .primaryMethod(item)
        case var .secondaryMethod(item):
            item.disabled = disabled
            return .secondaryMethod(item)
        case var .paymentToken(item):
            item.disabled = disabled
            return .paymentToken(item)
        case var .savedSecondaryToken(item):
            item.disabled = disabled
            return .savedSecondaryToken(item)
        }
    }
}

/// A primary method — exactly one covers the amount left after secondaries.
public struct PrimaryMethod: PrimarySource, Sendable, Equatable {
    public let id: String
    public let partner: Partner
    public let method: Method
    public let configuration: MethodConfiguration
    public internal(set) var disabled: DisabledState?
    /// `settings.merchant_specifics.integration_mode` — `redirection` / `popup`, or `nil`.
    public let integrationType: IntegrationMode?
    /// `vault.supported_brands` — the card schemes this method accepts; empty when not vaulted.
    public let supportedBrands: [CardBrand]

    /// The effective save-token policy.
    public var saveTokenMode: SaveTokenMode { configuration.settings.resolvedSaveTokenMode }
    /// Whether the shopper can choose to save this card.
    public var canBeRegistered: Bool { saveTokenMode.canBeRegistered }
    /// Whether the method quotes a BNPL instalment schedule — true when `labels` carry `"simulable"`.
    public var simulable: Bool { configuration.labels.contains(simulableLabel) }
}

/// A secondary (co-payment) method — gift cards, vouchers, loyalty. Drawn down before the primary.
public struct SecondaryMethod: Sendable, Equatable {
    public let id: String
    public let partner: Partner
    public let method: Method
    public let configuration: MethodConfiguration
    public internal(set) var disabled: DisabledState?

    /// The effective save-token policy a card tokenized through this method inherits.
    public var saveTokenMode: SaveTokenMode { configuration.settings.resolvedSaveTokenMode }
    public var canBeRegistered: Bool { saveTokenMode.canBeRegistered }
}

/// A saved instrument offered by the session under a primary method — a card-on-file, or a vaulted
/// PayPal account. Selectable as the split's primary.
public struct PaymentToken: PrimarySource, Sendable, Equatable {
    /// The token's own id (not `partner-method`) — matches the wallet API's token ids.
    public let id: String
    public let partner: Partner
    public let method: Method
    public let configuration: MethodConfiguration
    public internal(set) var disabled: DisabledState?
    /// The opaque value `/validate` pays with.
    public let value: String
    /// The shopper-given label, when one was saved.
    public let name: String
    public let label: String
    public let brand: String
    public let holderName: String
    public let maskedPAN: String
    public let expirationDate: String?
    public let favorite: Bool
    public let tokenSource: TokenSource
    public let createdAt: String?
    /// `network_token.available` — see ``paysWithoutCVV``.
    public let networkTokenAvailable: Bool

    /// The id of the ``PrimaryMethod`` this token belongs to.
    public var methodId: String { "\(partner.wireValue)-\(method.wireValue)" }

    /// Whether this token's method captures card data through a vault — i.e. the token is a **card-
    /// on-file**, and its plugin is the one that can put a CVV form on screen.
    public var isVaultedCard: Bool {
        guard let vendor = configuration.vault?.vendor else { return false }
        return vendor != VaultVendor.none
    }

    /// Whether this token pays without collecting the CVV. `true` outright when no card form exists
    /// for it. For a card-on-file, web's no-CVV gates: the merchant's `pay_token_no_cvv` setting, or
    /// an available network token when the experience enables them.
    public var paysWithoutCVV: Bool {
        !isVaultedCard
            || configuration.settings.payTokenNoCVV
            || (networkTokenAvailable && configuration.settings.networkToken)
    }

    /// Whether paying with this token still asks the shopper for the CVV. When `true`, selecting
    /// the token arms the fulfilment gate exactly like mounting a fresh card form does: the
    /// checkout is not fulfilled until the CVV-only Secure Fields form reports valid.
    public var requiresCVV: Bool { !paysWithoutCVV }
}

/// A **saved** gift card / voucher (secondary card-on-file) the session offers, built from a
/// secondary method's `integrated_tokens[]`.
public struct SavedSecondaryToken: Sendable, Equatable {
    /// The wallet token id — matches the wallet API's ids, and is the split source id.
    public let id: String
    public let partner: Partner
    public let method: Method
    public let configuration: MethodConfiguration
    public internal(set) var disabled: DisabledState?
    /// `uniqueness_token` — the stored instrument number the partner re-initialises with.
    public let pan: String
    /// `pin_code` — the stored security code, when the partner keeps one.
    public let cvv: String?
    /// Display label — `description.display_token`, else the shopper-given name.
    public let name: String
    public let expirationDate: String?
    public let createdAt: String?
    public let favorite: Bool
    /// Spendable balance once resolved; zero until then.
    public internal(set) var balance: Decimal = 0
    public internal(set) var totalBalance: Decimal = 0
    public internal(set) var balanceResolved: Bool = false
    public let takePolicy: SecondaryTakePolicy

    public var maxAmount: Decimal? { configuration.settings.paymentMaxAmount }

    /// The splitter-side instrument for this saved card — what applying it draws down.
    public func asSecondaryToken() -> SecondaryToken {
        SecondaryToken(
            id: id,
            partner: partner,
            method: method,
            pan: pan,
            cvv: cvv,
            name: name,
            balance: balance,
            totalBalance: totalBalance,
            expirationDate: expirationDate ?? "",
            takePolicy: takePolicy,
            limit: maxAmount,
            usageLimit: configuration.settings.usagePerSessionLimit,
            saveTokenMode: .never,
            isSaved: true
        )
    }
}

// MARK: - Building from a session's integrated tokens

extension PaymentToken {
    init(
        from token: IntegratedToken,
        partner: Partner,
        method: Method,
        configuration: MethodConfiguration,
        disabled: DisabledState?
    ) {
        self.init(
            id: token.id,
            partner: partner,
            method: method,
            configuration: configuration,
            disabled: disabled,
            value: token.value,
            name: token.name ?? "",
            label: token.displayToken ?? "",
            brand: token.brandName ?? "",
            holderName: token.holderName ?? "",
            maskedPAN: token.maskedPAN ?? "",
            expirationDate: token.expirationDate,
            favorite: token.favorite,
            tokenSource: token.source,
            createdAt: token.createdAt,
            networkTokenAvailable: token.networkTokenAvailable
        )
    }
}

extension SavedSecondaryToken {
    init(
        from token: IntegratedToken,
        partner: Partner,
        method: Method,
        configuration: MethodConfiguration,
        disabled: DisabledState?,
        takePolicy: SecondaryTakePolicy
    ) {
        self.init(
            id: token.id,
            partner: partner,
            method: method,
            configuration: configuration,
            disabled: disabled,
            pan: token.uniquenessToken ?? "",
            cvv: token.pinCode,
            name: token.displayToken ?? token.name ?? "",
            expirationDate: token.expirationDate,
            createdAt: token.createdAt,
            favorite: token.favorite,
            takePolicy: takePolicy
        )
    }
}
