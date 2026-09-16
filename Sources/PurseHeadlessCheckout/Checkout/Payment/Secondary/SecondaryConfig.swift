// Web: packages/headless-checkout/src/session/payment/mops/secondaries/configs/*.ts + token-mappers.ts
// Same: same `{partner}-{method}` keys, CVV/PAN rules, take policy, token parsing.
// Differs: one file; host-registrable; `ancv-connect` not shipped.

import Foundation

/// Per-partner rules for a secondary (co-payment) method.
public protocol SecondaryConfig: Sendable {
    var takePolicy: SecondaryTakePolicy { get }

    /// `plugin_result.logs` key holding the display label, for the default card-based parse.
    var nameLogKey: String? { get }

    func requiresCVV(pan: String) -> Bool
    func validatePAN(_ pan: String) -> Bool
    func validateCVV(_ cvv: String) -> Bool

    /// `payment_data` body for `POST /init`.
    func buildInitPaymentData(pan: String, cvv: String?) -> [String: JSONValue]

    /// `payment_data` body for `POST /validate` of an applied token.
    func buildValidatePaymentData(_ token: SecondaryToken) -> [String: JSONValue]

    /// Parse the `/init` response into a ``SecondaryToken``. The default reads the generic card
    /// shape (`plugin_result.payment_data.cards[0]` for balance and expiry, ``nameLogKey`` for the
    /// label); a partner with a different response shape overrides it.
    func parseToken(
        method: SecondaryMethod,
        initResponse: JSONValue,
        pan: String,
        cvv: String?
    ) throws -> SecondaryToken

    /// Whether a successful `/init` is only an acknowledgement that must be polled for the real
    /// token — web's `shouldPoll`. Default: never.
    func shouldPoll(_ initResponse: JSONValue) -> Bool

    /// Map an unsuccessful `/init` onto a partner-specific error. `nil` falls back to the generic one.
    func classifyInitError(_ initResponse: JSONValue) -> PurseCheckoutError?
}

public extension SecondaryConfig {
    var nameLogKey: String? { nil }
    func validateCVV(_ cvv: String) -> Bool { true }

    func buildInitPaymentData(pan: String, cvv: String?) -> [String: JSONValue] {
        cardPaymentData(pan: pan, cvv: cvv)
    }

    func buildValidatePaymentData(_ token: SecondaryToken) -> [String: JSONValue] {
        cardPaymentData(pan: token.pan, cvv: token.cvv)
    }

    func parseToken(
        method: SecondaryMethod,
        initResponse: JSONValue,
        pan: String,
        cvv: String?
    ) throws -> SecondaryToken {
        try parseCardToken(
            method: method,
            initResponse: initResponse,
            pan: pan,
            cvv: cvv,
            takePolicy: takePolicy,
            nameLogKey: nameLogKey
        )
    }

    func shouldPoll(_ initResponse: JSONValue) -> Bool { false }
    func classifyInitError(_ initResponse: JSONValue) -> PurseCheckoutError? { nil }
}

// MARK: - Shipped issuers

/// Illicado gift card.
public struct IllicadoConfig: SecondaryConfig {
    public let takePolicy = SecondaryTakePolicy.none
    public let nameLogKey: String? = "masked_card"
    public init() {}
    public func requiresCVV(pan: String) -> Bool { true }
    public func validatePAN(_ pan: String) -> Bool {
        pan.matches("^(?:925000478|925000410)[0-9]{10}$")
    }
    public func validateCVV(_ cvv: String) -> Bool { cvv.matches("^[0-9]{3}$") }
}

/// BuyBox / Storeland / Oney gift card.
public struct BuyboxConfig: SecondaryConfig {
    private static let storeland = "^533[0-9]{10}$"
    private static let oney = "^[0-9]{19}D[0-9]{17}$|^[0-9]{19}$"
    private static let buybox = "^[A-HJ-KM-NP-Z][0-9]{4,9}[A-HJ-KM-NP-Z][0-9]{5,10}$"

    public let takePolicy = SecondaryTakePolicy.none
    public let nameLogKey: String? = "card.mask"
    public init() {}

    /// Storeland cards carry no CVV; every other BuyBox card does.
    public func requiresCVV(pan: String) -> Bool { !pan.matches(Self.storeland) }
    public func validatePAN(_ pan: String) -> Bool {
        pan.matches(Self.storeland) || pan.matches(Self.oney) || pan.matches(Self.buybox)
    }
}

/// Maxxing loyalty card. Non-splittable; the balance comes from `logs`, not a card object.
public struct MaxxingConfig: SecondaryConfig {
    public let takePolicy = SecondaryTakePolicy.max
    public init() {}
    public func requiresCVV(pan: String) -> Bool { false }
    public func validatePAN(_ pan: String) -> Bool { true }

    public func parseToken(
        method: SecondaryMethod,
        initResponse: JSONValue,
        pan: String,
        cvv: String?
    ) throws -> SecondaryToken {
        try requireSuccessfulInit(initResponse)
        let logs = initResponse["plugin_result"]?["logs"]
        let balance = logs?["eligible_euros"]?.asDecimal ?? 0
        let total = logs?["total_euros"]?.asDecimal ?? balance

        guard balance > 0 else {
            throw PurseCheckoutError.secondaryTokenizationFailed(
                "loyalty card has no eligible balance",
                .secondaryTokenEmptyBalance
            )
        }

        return SecondaryToken(
            id: "\(method.id)-\(pan.suffix(4))",
            partner: method.partner,
            method: method.method,
            pan: pan,
            cvv: cvv,
            name: logs?["customer.reference"]?.stringValue ?? "",
            balance: balance,
            totalBalance: total,
            takePolicy: takePolicy,
            limit: method.configuration.settings.paymentMaxAmount,
            usageLimit: method.configuration.settings.usagePerSessionLimit
        )
    }
}

/// Ogloba gift card.
public struct OglobaConfig: SecondaryConfig {
    public let takePolicy = SecondaryTakePolicy.none
    public let nameLogKey: String? = "card_number"
    public init() {}
    public func requiresCVV(pan: String) -> Bool { false }
    public func validatePAN(_ pan: String) -> Bool { pan.range(of: "^[0-9]{6}", options: .regularExpression) != nil }
}

/// MyBeezBox gift card. Any non-empty PAN.
public struct MybeezboxConfig: SecondaryConfig {
    public let takePolicy = SecondaryTakePolicy.none
    public let nameLogKey: String? = "card_number"
    public init() {}
    public func requiresCVV(pan: String) -> Bool { false }
    public func validatePAN(_ pan: String) -> Bool { !pan.isEmpty }
}

/// Easy2Play gift card. Requires a 3-digit CVV.
public struct Easy2playGiftcardConfig: SecondaryConfig {
    public let takePolicy = SecondaryTakePolicy.none
    public let nameLogKey: String? = "card_mask"
    public init() {}
    public func requiresCVV(pan: String) -> Bool { true }
    public func validatePAN(_ pan: String) -> Bool { true }
    public func validateCVV(_ cvv: String) -> Bool { cvv.matches("^[0-9]{3}$") }
}

/// Easy2Play voucher. Non-splittable, and identified by `voucher_number` rather than a card.
public struct Easy2playVoucherConfig: SecondaryConfig {
    public let takePolicy = SecondaryTakePolicy.max
    public init() {}
    public func requiresCVV(pan: String) -> Bool { false }
    public func validatePAN(_ pan: String) -> Bool { !pan.isEmpty }

    public func buildInitPaymentData(pan: String, cvv: String?) -> [String: JSONValue] {
        ["voucher_number": .string(pan)]
    }

    public func buildValidatePaymentData(_ token: SecondaryToken) -> [String: JSONValue] {
        ["voucher_number": .string(token.pan)]
    }
}

// MARK: - Registry

/// Resolves the ``SecondaryConfig`` for a secondary method. The shipped issuers are registered up
/// front; a merchant adds one the SDK does not know with ``register(partner:method:config:)``,
/// keyed by `"{partner}-{method}"` wire values so `.other(_:)` partners and methods work.
@MainActor
public final class SecondaryConfigs {

    public static let shared = SecondaryConfigs()

    /// `ancv-connect` is intentionally absent: it needs a two-phase (holder → poll) init flow that
    /// is not implemented. A host can supply one through `register` plus `shouldPoll`.
    private static let builtIn: [String: any SecondaryConfig] = [
        "illicado-giftcard": IllicadoConfig(),
        "buybox-giftcard": BuyboxConfig(),
        "maxxing-loyaltycard": MaxxingConfig(),
        "ogloba-giftcard": OglobaConfig(),
        "mybeezbox-giftcard": MybeezboxConfig(),
        "easy2play-giftcard": Easy2playGiftcardConfig(),
        "easy2play-voucher": Easy2playVoucherConfig(),
    ]

    private var byKey: [String: any SecondaryConfig] = SecondaryConfigs.builtIn

    public init() {}

    private func key(_ partner: Partner, _ method: PaymentMethod) -> String {
        "\(partner.wireValue)-\(method.wireValue)"
    }

    public func config(partner: Partner, method: PaymentMethod) -> (any SecondaryConfig)? {
        byKey[key(partner, method)]
    }

    public func config(for method: SecondaryMethod) -> (any SecondaryConfig)? {
        config(partner: method.partner, method: method.method)
    }

    /// Register (or replace) the config driving `(partner, method)` — how a host adds an issuer that
    /// is not in the catalogue, or overrides a shipped one.
    public func register(partner: Partner, method: PaymentMethod, config: any SecondaryConfig) {
        byKey[key(partner, method)] = config
    }

    public func unregister(partner: Partner, method: PaymentMethod) {
        byKey[key(partner, method)] = nil
    }

    public func isRegistered(partner: Partner, method: PaymentMethod) -> Bool {
        byKey[key(partner, method)] != nil
    }

    /// Back to the shipped catalogue only, dropping every host registration.
    public func reset() {
        byKey = SecondaryConfigs.builtIn
    }
}

// MARK: - Shared helpers

/// `{ card: { number, csc? } }` — the common secondary `payment_data` body.
func cardPaymentData(pan: String, cvv: String?) -> [String: JSONValue] {
    var card: [String: JSONValue] = ["number": .string(pan)]
    if let cvv, !cvv.isEmpty { card["csc"] = .string(cvv) }
    return ["card": .object(card)]
}

func requireSuccessfulInit(_ initResponse: JSONValue) throws {
    let status = initResponse["status"]
    let state = status?["state"]?.stringValue ?? ""
    guard state == "SUCCESS" else {
        let description = status?["description"]?.stringValue ?? ""
        throw PurseCheckoutError.secondaryTokenizationFailed(
            "secondary init not successful (state=\(state)) \(description)"
                .trimmingCharacters(in: .whitespaces),
            .failedToInitSecondaryToken
        )
    }
}

/// Generic card-based token parse — web's `fromCard` formatter, parameterized by the name log key.
func parseCardToken(
    method: SecondaryMethod,
    initResponse: JSONValue,
    pan: String,
    cvv: String?,
    takePolicy: SecondaryTakePolicy,
    nameLogKey: String?
) throws -> SecondaryToken {
    try requireSuccessfulInit(initResponse)

    let pluginResult = initResponse["plugin_result"]
    let card = pluginResult?["payment_data"]?["cards"]?.arrayValue?.first
    let balance = card?["balance"]?.asDecimal ?? 0

    guard balance > 0 else {
        throw PurseCheckoutError.secondaryTokenizationFailed(
            "secondary card has no balance",
            .secondaryTokenEmptyBalance
        )
    }

    let name = nameLogKey.flatMap { pluginResult?["logs"]?[$0]?.stringValue } ?? ""

    return SecondaryToken(
        id: "\(method.id)-\(pan.suffix(4))",
        partner: method.partner,
        method: method.method,
        pan: pan,
        cvv: cvv,
        name: name,
        balance: balance,
        totalBalance: balance,
        expirationDate: card?["expiry_date"]?.stringValue ?? "",
        takePolicy: takePolicy,
        limit: method.configuration.settings.paymentMaxAmount,
        usageLimit: method.configuration.settings.usagePerSessionLimit
    )
}

extension JSONValue {
    /// A balance the partner may send as either a JSON number or a quoted string.
    var asDecimal: Decimal? {
        switch self {
        case let .number(text): Decimal(string: text)
        case let .string(text): Decimal(string: text)
        default: nil
        }
    }
}

extension String {
    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }
}
