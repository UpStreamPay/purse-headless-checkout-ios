// Web: packages/headless-checkout/src/session/payment/mops/item-factory/factories.ts
// Same: protocols → items, availability rules, tokens.
// Differs: take policy is not yet resolved per issuer (SecondaryConfigs lands with PR 4).

import Foundation

/// Builds the ready-to-consume ``PaymentSession`` from a decoded ``LegacyPaymentSession`` — web's
/// `getSessionFromLegacy`. Turns `protocols` into the means-of-payment list and applies the
/// build-time availability rules (against the full amount, before any split).
public enum PaymentSessionBuilder {

    /// - Parameter disabledMethods: methods this app build opts out of — dropped as if the session
    ///   did not offer them, their saved instruments included, whatever `protocols` says.
    public static func build(
        _ session: LegacyPaymentSession,
        disabledMethods: Set<MethodKey> = []
    ) -> PaymentSession {
        let isInformationRequest = session.informationRequest ?? (session.amount == nil || session.amount == 0)
        let amount = session.amount ?? 0

        return PaymentSession(
            id: session.id,
            source: session,
            amount: amount,
            amountCents: PursePaymentSplitter.toCents(amount),
            isInformationRequest: isInformationRequest,
            currency: session.currencyCode,
            expirationDate: session.expirationDate,
            vaultsConfiguration: session.vault?.vendorFrontData,
            meansOfPayment: buildMeansOfPayment(
                session,
                isInformationRequest: isInformationRequest,
                primaryReach: amount,
                disabledMethods: disabledMethods
            )
        )
    }

    private static func buildMeansOfPayment(
        _ session: LegacyPaymentSession,
        isInformationRequest: Bool,
        primaryReach: Decimal,
        disabledMethods: Set<MethodKey>
    ) -> [PaymentItem] {
        var items: [PaymentItem] = []

        for (partner, methods) in session.protocols {
            for (method, entry) in methods {
                if disabledMethods.contains(MethodKey(partner: partner, method: method)) { continue }
                let configuration = entry.configurations

                // In an information_request session, only OFF_SESSION-registrable methods are
                // included at all — everything else is dropped, not merely disabled.
                if isInformationRequest, configuration.settings.registrationMode != .offSession {
                    continue
                }

                let id = "\(partner.wireValue)-\(method.wireValue)"
                // Permanent build-time states (suspension, unreachable min-amount) win over the
                // amount-driven ones: web sets them before the first recompute, and recompute skips
                // them as non-recomputable.
                let disabled = MethodAvailability.buildTimeDisabled(for: configuration, orderAmount: primaryReach)
                    ?? MethodAvailability.disabled(
                        for: configuration,
                        isInformationRequest: isInformationRequest,
                        primaryReach: primaryReach
                    )

                // Saved instruments ride along their method — one item per integrated_tokens[] row:
                // a PaymentToken (card-on-file, a primary) under a primary method, a
                // SavedSecondaryToken (gift card on file) under a secondary one.
                if !isInformationRequest {
                    for token in entry.integratedTokens {
                        if configuration.isSecondary {
                            items.append(.savedSecondaryToken(SavedSecondaryToken(
                                from: token,
                                partner: partner,
                                method: method,
                                configuration: configuration,
                                disabled: disabled,
                                // ponytail: every issuer treated as splittable until SecondaryConfigs
                                // lands in PR 4, which is where the per-issuer MAX policies live
                                // (maxxing loyalty, easy2play vouchers).
                                takePolicy: .none
                            )))
                        } else {
                            items.append(.paymentToken(PaymentToken(
                                from: token,
                                partner: partner,
                                method: method,
                                configuration: configuration,
                                disabled: disabled
                            )))
                        }
                    }
                }

                if configuration.isSecondary {
                    items.append(.secondaryMethod(SecondaryMethod(
                        id: id,
                        partner: partner,
                        method: method,
                        configuration: configuration,
                        disabled: disabled
                    )))
                } else {
                    items.append(.primaryMethod(PrimaryMethod(
                        id: id,
                        partner: partner,
                        method: method,
                        configuration: configuration,
                        disabled: disabled,
                        integrationType: configuration.settings.integrationMode,
                        supportedBrands: configuration.vault?.supportedBrands ?? []
                    )))
                }
            }
        }

        return items.sorted(by: byPosition)
    }

    /// Ascending by `position`; entries without one sort last, matching web's `positionSort`.
    /// `protocols` decodes from a dictionary, so iteration order is not stable — items with no
    /// position are then tie-broken by id to keep the built list deterministic.
    private static func byPosition(_ a: PaymentItem, _ b: PaymentItem) -> Bool {
        switch (a.configuration.position, b.configuration.position) {
        case let (positionA?, positionB?):
            positionA == positionB ? a.id < b.id : positionA < positionB
        case (nil, _?):
            false
        case (_?, nil):
            true
        case (nil, nil):
            a.id < b.id
        }
    }
}
