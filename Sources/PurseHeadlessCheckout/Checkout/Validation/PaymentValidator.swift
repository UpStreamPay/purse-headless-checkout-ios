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
    let configs: SecondaryConfigs
    /// `nil` in tests that construct a validator directly — monitoring is entirely optional to this
    /// type, which otherwise has no Checkout-level concerns at all.
    var eventBus: CheckoutEventBus? = nil
    /// The merchant's options, so `partner_data.browser` carries their locale.
    var options = PluginOptions()

    private struct Prepared {
        let plugin: any PartnerUIPlugin
        let context: PartnerUIContext
    }

    func execute(
        splits: [PaymentSplit],
        session: LegacyPaymentSession,
        collectedByItem: [String: [String: JSONValue]] = [:],
        hooks: PurseCheckoutHooks? = nil,
        skipOnBeforeValidate: Bool = false,
        registrationByItem: [String: RegistrationState] = [:]
    ) async throws -> ValidationResult {
        try requireDistinctSources(splits)

        var prepared: [Prepared] = []
        var payloads: [ValidateItemPayload] = []

        for split in splits {
            // A secondary split builds its payload from the issuer's own configuration — no plugin
            // is involved, matching web.
            if let token = split.source as? SecondaryToken {
                guard let config = configs.config(partner: token.partner, method: token.method) else {
                    // Refusing is the only safe answer: submitting without it would charge the
                    // primary for the whole order while the shopper believes a gift card covered
                    // part of it.
                    throw PurseCheckoutError.noSecondaryConfig(itemId: token.id)
                }
                let payload = ItemPayload(
                    partner: token.partner,
                    method: token.method,
                    amount: split.amount,
                    paymentData: config.buildValidatePaymentData(token)
                )
                // A gift card the shopper asked to keep — never for an instrument already saved.
                let registration = registrationByItem[token.id].flatMap { $0.registered && !token.isSaved ? $0 : nil }
                payloads.append(Self.enhanceWithRegistration(payload, registration))
                continue
            }

            guard let source = split.source as? any PrimarySource else {
                throw PurseCheckoutError.validateFailed(
                    "unsupported split source \(split.source.id)", nil
                )
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

            // A saved card is already registered — only a fresh PrimaryMethod carries a decision.
            let registration = source is PrimaryMethod ? registrationByItem[source.id] : nil

            let context = PartnerUIContext(
                partner: source.partner,
                method: source.method,
                session: session,
                amount: split.amount,
                api: api,
                register: registration?.registered == true,
                token: token,
                collected: collectedByItem[source.id] ?? [:],
                options: options
            )

            guard try await plugin.validateUI(context) else {
                // The usual cause: a card form submitted here without being tokenized first.
                let hint = plugin is CardPlugin ? " — tokenize the card form first (CardCoordinator.submit())" : ""
                throw PurseCheckoutError.validateFailed("client-side validation failed for \(source.id)\(hint)", nil)
            }

            payloads.append(Self.enhanceWithRegistration(try await plugin.preValidation(context), registration))
            prepared.append(Prepared(plugin: plugin, context: context))
        }

        // Merchant hook between payload preparation and the POST. Throwing aborts the submit —
        // nothing has been sent at this point, so the caller can restore a submittable state.
        // Skipped when a plugin auto-submits.
        if !skipOnBeforeValidate, let onBeforeValidate = hooks?.onBeforeValidate {
            do {
                try await onBeforeValidate(splits)
            } catch {
                await eventBus?.post(.onBeforeValidateHookFailed, .error, monitoringPayload([
                    "hook": .string("onBeforeValidate"), "message": .string(error.localizedDescription)
                ]))
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

        // Runs before postValidation, and so before any redirect. Errors are swallowed, like web —
        // reported as HEADLESS_CHECKOUT_CLIENT_HOOK_ERROR since nothing else will ever see them.
        if let onAfterValidate = hooks?.onAfterValidate {
            do {
                try await onAfterValidate()
            } catch {
                await eventBus?.post(.clientHookError, .error, monitoringPayload([
                    "hook": .string("onAfterValidate"), "message": .string(error.localizedDescription)
                ]))
            }
        }

        for item in prepared {
            do {
                try await item.plugin.postValidation(result, context: item.context)
            } catch {
                // `/validate` has already answered at this point, so the payment exists whatever a
                // plugin does next (Klarna's `postValidation` throws on a declined authorization,
                // for one).
                throw PurseCheckoutError.postValidationFailed(result: result, underlying: error)
            }
        }
        return result
    }

    /// `payment_preferences.registration` plus `payment_data.card.token_label` when the shopper
    /// named the card — web's `headless-checkout-validation.ts` payload enhancement.
    private static func enhanceWithRegistration(
        _ payload: ValidateItemPayload, _ registration: RegistrationState?
    ) -> ValidateItemPayload {
        guard let registration else { return payload }
        var preferences = payload.paymentPreferences
        preferences["registration"] = .bool(registration.registered)

        var paymentData = payload.paymentData
        if registration.registered, let name = registration.name?.nonBlank {
            var card = paymentData["card"]?.objectValue ?? [:]
            card["token_label"] = .string(name)
            paymentData["card"] = .object(card)
        }

        return ItemPayload(
            partner: payload.partner,
            method: payload.method,
            amount: payload.amount,
            stepId: payload.stepId,
            paymentData: paymentData,
            partnerData: payload.partnerData,
            order: payload.order,
            paymentPreferences: preferences
        )
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
