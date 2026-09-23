// Web: packages/partner-ui hosted-form default wording + field error display
// Same: Android's `purse_card_*` strings (en, fr) verbatim, and `FieldUiState.message()`'s rule.
// Differs: a Swift table picked by `PluginOptions.locale` (device language when nil) rather than resources keyed on the device locale.

import Foundation

/// One field's copy with the SDK defaults filled in — merchant value first (Android
/// `rememberCardTexts`).
struct ResolvedFieldTexts: Equatable {
    let label: String
    let helperText: String?
    let requiredError: String
    let formatError: String

    /// The error to show, or `nil`. Never while the shopper is typing in the field: a format error
    /// appears on blur and clears once the value is valid; a required error appears once an empty
    /// field has been left.
    func error(for state: CardFieldState) -> String? {
        if state.hasContent && !state.isValid && !state.isFocused { return formatError }
        if !state.hasContent && state.wasBlurred { return requiredError }
        return nil
    }

    /// What goes under the field: the error, else the helper text while the field has focus.
    func message(for state: CardFieldState) -> String? {
        error(for: state) ?? (state.isFocused ? helperText : nil)
    }
}

extension CardFormTexts {
    func resolved(locale: String?) -> [CardField: ResolvedFieldTexts] {
        let language = locale ?? Locale.preferredLanguages.first ?? "en"
        let defaults = language.lowercased().hasPrefix("fr") ? Self.french : Self.english
        func merge(_ field: CardField, _ own: FieldTexts) -> ResolvedFieldTexts {
            let fallback = defaults[field]!
            return ResolvedFieldTexts(
                label: own.label ?? fallback.label,
                helperText: (own.helperText ?? fallback.helperText)?.nonBlank,
                requiredError: own.requiredError ?? fallback.requiredError,
                formatError: own.formatError ?? fallback.formatError
            )
        }
        return [
            .cardNumber: merge(.cardNumber, cardNumber),
            .expDate: merge(.expDate, expDate),
            .cvv: merge(.cvv, cvv),
            .holderName: merge(.holderName, holderName),
        ]
    }

    private static let english: [CardField: ResolvedFieldTexts] = [
        .cardNumber: .init(
            label: "Card number",
            helperText: "We only store a secure token, not your full card number.",
            requiredError: "Card number required.",
            formatError: "Invalid card number."
        ),
        .expDate: .init(
            label: "Expiration date",
            helperText: "Card expiration month and year (MM/YY).",
            requiredError: "Expiration date required.",
            formatError: "Invalid expiration date."
        ),
        .cvv: .init(
            label: "Security code",
            helperText: "3–4 digit code on the back (or front for Amex).",
            requiredError: "Security code required.",
            formatError: "Invalid security code."
        ),
        .holderName: .init(
            label: "Cardholder name",
            helperText: nil,
            requiredError: "Enter the cardholder name as it appears on the card.",
            formatError: "Invalid cardholder."
        ),
    ]

    private static let french: [CardField: ResolvedFieldTexts] = [
        .cardNumber: .init(
            label: "Numéro de carte",
            helperText: "Nous ne conservons qu'un jeton sécurisé, jamais votre numéro complet.",
            requiredError: "Numéro de carte requis.",
            formatError: "Numéro de carte invalide."
        ),
        .expDate: .init(
            label: "Date d'expiration",
            helperText: "Mois et année d'expiration de la carte (MM/AA).",
            requiredError: "Date d'expiration requise.",
            formatError: "Date d'expiration invalide."
        ),
        .cvv: .init(
            label: "Cryptogramme",
            helperText: "Code à 3–4 chiffres au dos (ou à l'avant pour Amex).",
            requiredError: "Cryptogramme requis.",
            formatError: "Cryptogramme invalide."
        ),
        .holderName: .init(
            label: "Titulaire de la carte",
            helperText: nil,
            requiredError: "Entrez le nom du titulaire comme il apparaît sur la carte.",
            formatError: "Titulaire invalide."
        ),
    ]
}
