// Web: packages/headless-checkout secondaries `getSecondaryToken`
// Same: validate locally → POST /init → parse into a token.
// Differs: nothing.

import Foundation

/// Turns a typed gift card / voucher into an applicable ``SecondaryToken``. Validates against the
/// issuer's own rules **before** touching the network — a PAN the issuer cannot accept is a wasted
/// `/init` and a worse error message.
@MainActor
struct SecondaryTokenizer {

    let api: PaymentAPIClient
    let configs: SecondaryConfigs

    /// - Parameter amount: what this instrument is being asked to cover. Some issuers compute the
    ///   eligible balance **against the requested amount** (Maxxing answers `logs.eligible_euros`),
    ///   so sending 0 makes them answer 0 — and `parseToken` then rejects the card as empty.
    func tokenize(
        method: SecondaryMethod,
        pan: String,
        cvv: String?,
        amount: Decimal
    ) async throws -> SecondaryToken {
        guard let config = configs.config(for: method) else {
            throw PurseCheckoutError.noSecondaryConfig(itemId: method.id)
        }

        guard config.validatePAN(pan) else {
            throw PurseCheckoutError.invalidSecondaryCard(
                "the card number is not valid for \(method.id)",
                .secondaryMethodWrongPANFormat
            )
        }

        if config.requiresCVV(pan: pan) {
            guard let cvv, !cvv.isEmpty else {
                throw PurseCheckoutError.invalidSecondaryCard(
                    "\(method.id) requires a security code",
                    .secondaryMethodRequiredCVV
                )
            }
            guard config.validateCVV(cvv) else {
                throw PurseCheckoutError.invalidSecondaryCard(
                    "the security code is not valid for \(method.id)",
                    .secondaryMethodWrongCVVFormat
                )
            }
        }

        let payload: [String: JSONValue] = [
            "partner": .string(method.partner.wireValue),
            "method": .string(method.method.wireValue),
            "amount": .number(amount.description),
            "payment_data": .object(config.buildInitPaymentData(pan: pan, cvv: cvv)),
        ]

        let response: JSONValue
        do {
            response = try await api.initPayment(payload)
        } catch {
            // The cause is kept, not just its text: a terminal API answer (already submitted /
            // expired / gone) has to stay recognisable through the wrapper, or the checkout cannot
            // tell a dead session from a refused card. `isSessionTerminal` walks this chain.
            throw PurseCheckoutError.secondaryTokenizationFailed(
                "could not initialise \(method.id)",
                .failedToInitSecondaryToken,
                underlying: error
            )
        }

        if let classified = config.classifyInitError(response) {
            throw classified
        }

        return try config.parseToken(method: method, initResponse: response, pan: pan, cvv: cvv)
    }
}
