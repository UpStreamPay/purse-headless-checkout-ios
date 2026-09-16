// Web: packages/partner-ui/src/commons/Plugin/types.ts (`Plugin<Context>`)
// Same: one plugin per (partner, method); the lifecycle hooks and their order.
// Differs: `async` instead of `Promise`; no `sources` (no scripts to load) and no `onDataUpdate`.

import Foundation

/// The protocol half of a payment method: what goes to `/init` and `/validate`, and what to do with
/// the answer.
public protocol PartnerUIPlugin: Sendable {
    var partner: Partner { get }
    var method: PaymentMethod { get }

    /// A session has been attached (or refreshed) — create/refresh the vendor client.
    func onSessionSet(_ context: PartnerUIContext) async throws

    /// The amount this item must cover changed (the splitter moved).
    func onAmountUpdate(_ context: PartnerUIContext) async throws

    /// The payload this item contributes to `/validate`.
    func preValidation(_ context: PartnerUIContext) async throws -> ValidateItemPayload

    /// The `/validate` outcome for this item — follow a redirect, confirm, or surface an error.
    func postValidation(_ result: ValidationResult, context: PartnerUIContext) async throws

    /// Release the vendor client and any held resources.
    func destroyClient(_ context: PartnerUIContext) async throws

    /// Client-side check before ``preValidation(_:)``; `false` blocks the submit.
    func validateUI(_ context: PartnerUIContext) async throws -> Bool

    /// Eligibility pre-check at session build; throw to mark the method incompatible.
    func ensureClientCompatibility(_ context: PartnerUIContext) async throws
}

public extension PartnerUIPlugin {
    func onSessionSet(_ context: PartnerUIContext) async throws {}
    func onAmountUpdate(_ context: PartnerUIContext) async throws {}
    func postValidation(_ result: ValidationResult, context: PartnerUIContext) async throws {}
    func destroyClient(_ context: PartnerUIContext) async throws {}
    func validateUI(_ context: PartnerUIContext) async throws -> Bool { true }
    func ensureClientCompatibility(_ context: PartnerUIContext) async throws {}
}

/// The single object every ``PartnerUIPlugin`` hook receives. It is how a plugin reaches everything
/// it needs without the host knowing anything PSP-specific.
public struct PartnerUIContext: Sendable {
    public let partner: Partner
    public let method: PaymentMethod
    public let session: LegacyPaymentSession
    /// The amount this item must cover, handed down from the splitter.
    public let amount: Decimal
    /// The client to call `/init` / `/validate` against the current session.
    public let api: PaymentAPIClient
    public let register: Bool
    /// Set when this item pays with a saved instrument (card-on-file).
    public let token: PayToken?
    /// Data an interactive plugin collected outside the headless flow (a wallet sheet token, a
    /// `/init` step id, a vault token), threaded in so `preValidation` can build its payload.
    public let collected: [String: JSONValue]
    public let options: PluginOptions

    public init(
        partner: Partner,
        method: PaymentMethod,
        session: LegacyPaymentSession,
        amount: Decimal,
        api: PaymentAPIClient,
        register: Bool = false,
        token: PayToken? = nil,
        collected: [String: JSONValue] = [:],
        options: PluginOptions = PluginOptions()
    ) {
        self.partner = partner
        self.method = method
        self.session = session
        self.amount = amount
        self.api = api
        self.register = register
        self.token = token
        self.collected = collected
        self.options = options
    }

    /// This item's own configuration.
    public var configuration: MethodConfiguration? {
        session.protocols[partner]?[method]?.configurations
    }

    /// The Purse vault tenant Secure Fields is initialised with.
    public var vaultTenantId: String? {
        session.vault?.vendorFrontData.purse?.tenantId
    }
}

/// Presentation preferences forwarded to a plugin.
public struct PluginOptions: Sendable {
    /// BCP-47 locale (e.g. `"fr-FR"`); `nil` falls back to the device locale.
    public let locale: String?

    public init(locale: String? = nil) {
        self.locale = locale
    }
}

/// A saved instrument to pay with — the fields web's `patchItemPayloadWithToken` reads.
public struct PayToken: Sendable, Equatable {
    public let value: String
    /// ISO expiration of the underlying card; formatted to `yyyy-MM-dd` on the wire.
    public let expirationDate: String?
    public let holderName: String?
    /// The card scheme in session vocabulary (e.g. `VISA`), when known.
    public let selectedNetwork: String?
    /// Whether paying with this token still needs the shopper's CVV. Only a **card** plugin ever
    /// reads it: a CVV is a card-form concept, so a token whose method renders no card form is
    /// always built with `false`.
    public let requiresCVV: Bool

    public init(
        value: String,
        expirationDate: String? = nil,
        holderName: String? = nil,
        selectedNetwork: String? = nil,
        requiresCVV: Bool = false
    ) {
        self.value = value
        self.expirationDate = expirationDate
        self.holderName = holderName
        self.selectedNetwork = selectedNetwork
        self.requiresCVV = requiresCVV
    }

    /// Patch `paymentData` the way web's `patchItemPayloadWithToken` does: the opaque value as
    /// `payment_data.token`, the holder alongside, and card metadata under `card` — only when the
    /// token carries any, so a PayPal token (no card behind it) patches `token` alone.
    public func patch(_ paymentData: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var patched = paymentData
        patched["token"] = .string(value)
        if let holderName { patched["holder"] = .string(holderName) }

        var card: [String: JSONValue] = [:]
        if let wireExpiryDate { card["expiry_date"] = .string(wireExpiryDate) }
        if let selectedNetwork { card["selected_network"] = .string(selectedNetwork) }
        if !card.isEmpty { patched["card"] = .object(card) }
        return patched
    }

    /// `expiry_date` as the Payment API expects it — web's `formatUTCToExpiration` (`yyyy-MM-dd`),
    /// or `nil` when the ISO value cannot be read.
    public var wireExpiryDate: String? {
        guard let expirationDate else { return nil }
        if let date = ISO8601Date.parse(expirationDate) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        }
        // Already a bare `yyyy-MM-dd`, as some partners send.
        let prefix = String(expirationDate.prefix(10))
        return prefix.count == 10 && prefix.filter { $0 == "-" }.count == 2 ? prefix : nil
    }
}
