// Web: packages/headless-checkout/src/headless-checkout-validation.ts (`executePayment`)
// Same: preValidation → one POST /validate → postValidation; hooks around it.
// Differs: a repeated split source is a hard error.

import Foundation

/// The create-payment pipeline. For each split it builds a ``ValidateItemPayload``, POSTs them all
/// to `/validate` in **one** call, then dispatches the result back to any plugins.
@MainActor
struct PaymentValidator {

    let api: PaymentAPIClient
    let registry: PluginRegistry

    private struct Prepared {
        let plugin: any PartnerUIPlugin
        let context: PartnerUIContext
    }

    func execute(
        splits: [PaymentSplit],
        session: LegacyPaymentSession,
        collectedByItem: [String: [String: JSONValue]] = [:],
        hooks: PurseCheckoutHooks? = nil,
        skipOnBeforeValidate: Bool = false
    ) async throws -> ValidationResult {
        try requireDistinctSources(splits)

        var prepared: [Prepared] = []
        var payloads: [ValidateItemPayload] = []

        for split in splits {
            guard let source = split.source as? any PrimarySource else {
                // A secondary split needs its issuer's configuration to build a payload. Refusing is
                // the only safe answer: submitting without it would charge the primary for the whole
                // order while the shopper believes a gift card covered part of it.
                throw PurseCheckoutError.noSecondaryConfig(itemId: split.source.id)
            }

            guard let plugin = registry.plugin(partner: source.partner, method: source.method, session: session) else {
                throw PurseCheckoutError.noPluginRegistered(itemId: source.id)
            }

            let token = (source as? PaymentToken).map {
                PayToken(
                    value: $0.value,
                    expirationDate: $0.expirationDate,
                    holderName: $0.holderName.nonBlank,
                    selectedNetwork: CardBrand.fromWire($0.brand) == .unknown ? nil : $0.brand,
                    requiresCVV: $0.requiresCVV
                )
            }

            let context = PartnerUIContext(
                partner: source.partner,
                method: source.method,
                session: session,
                amount: split.amount,
                api: api,
                token: token,
                collected: collectedByItem[source.id] ?? [:]
            )

            guard try await plugin.validateUI(context) else {
                throw PurseCheckoutError.validateFailed("client-side validation failed for \(source.id)", nil)
            }

            payloads.append(try await plugin.preValidation(context))
            prepared.append(Prepared(plugin: plugin, context: context))
        }

        // Merchant hook between payload preparation and the POST. Throwing aborts the submit —
        // nothing has been sent at this point, so the caller can restore a submittable state.
        // Skipped when a plugin auto-submits.
        if !skipOnBeforeValidate, let onBeforeValidate = hooks?.onBeforeValidate {
            do {
                try await onBeforeValidate(splits)
            } catch {
                throw PurseCheckoutError.hookFailed(
                    hook: "onBeforeValidate",
                    underlying: error,
                    code: .onBeforeValidateHookFailed
                )
            }
        }

        let result: ValidationResult
        do {
            result = try await api.validate(items: payloads)
        } catch {
            // The underlying error is kept: a transport failure carries `outcomeUnknown`, which is
            // what tells a caller the payment may exist and must not be reported as a failure.
            throw PurseCheckoutError.validateFailed("validate call failed", error)
        }

        // Runs before postValidation, and so before any redirect. Errors are swallowed, like web.
        if let onAfterValidate = hooks?.onAfterValidate {
            try? await onAfterValidate()
        }

        for item in prepared {
            try await item.plugin.postValidation(result, context: item.context)
        }
        return result
    }

    /// One `/validate` item per split, and never the same split source twice — a duplicate would
    /// ask the PSP to charge the same instrument twice in a single call.
    private func requireDistinctSources(_ splits: [PaymentSplit]) throws {
        let counts = splits.reduce(into: [String: Int]()) { $0[$1.source.id, default: 0] += 1 }
        let repeated = counts.filter { $0.value > 1 }.keys.sorted()
        if !repeated.isEmpty {
            throw PurseCheckoutError.validateFailed(
                "refusing to submit /validate with a repeated split source: \(repeated.joined(separator: ", "))"
                    + " — each source must contribute exactly one item",
                nil
            )
        }
    }
}

/// Merchant hooks around the create-payment pipeline.
public struct PurseCheckoutHooks: Sendable {
    /// After the item payloads are built, right before `POST /validate`. Throwing **aborts the
    /// submit before anything is sent**.
    public let onBeforeValidate: (@Sendable ([PaymentSplit]) async throws -> Void)?
    /// After `/validate` answers, before any redirect. Errors are swallowed and reported.
    public let onAfterValidate: (@Sendable () async throws -> Void)?
    /// A redirect was resolved. Return `true` to take it over — the SDK opens nothing and you
    /// confirm the outcome yourself; `false` lets the SDK proceed.
    public let onRedirection: (@Sendable (RedirectAction) async throws -> Bool)?

    public init(
        onBeforeValidate: (@Sendable ([PaymentSplit]) async throws -> Void)? = nil,
        onAfterValidate: (@Sendable () async throws -> Void)? = nil,
        onRedirection: (@Sendable (RedirectAction) async throws -> Bool)? = nil
    ) {
        self.onBeforeValidate = onBeforeValidate
        self.onAfterValidate = onAfterValidate
        self.onRedirection = onRedirection
    }
}
