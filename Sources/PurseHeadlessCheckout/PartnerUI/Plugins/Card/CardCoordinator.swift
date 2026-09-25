// Web: packages/partner-ui hosted fields mount + submitForResult
// Same: three modes (fresh card / saved card needing its CVV / saved card needing nothing); brands from the token's own scheme, then the vault's supported brands.
// Differs: Secure Fields is a Swift 5 module, so nothing it owns crosses an isolation boundary — see "Crossing the Swift 5 boundary" in AGENTS.md. Android's `sdk` is public; here the manager stays private and its state is relayed as our own types.

import Combine
import Foundation
import PurseSecureFields
import UIKit

/// A tokenization result as our own `Sendable` type — Secure Fields' `TokenizationResult` lives in
/// a Swift 5 module and cannot cross an isolation boundary.
public struct CardTokenization: Sendable, Equatable {
    public let vaultFormToken: String
    /// Both `nil` after a CVV-only tokenization: the response carries no `card` block.
    public let bin: String?
    public let lastFourDigits: String?
    /// In **Payment API** vocabulary; `nil` on a CVV-only form.
    public let selectedNetwork: CardBrand?
}

/// One field of the card form, named as in ``CardFormTexts``.
public enum CardField: Sendable, CaseIterable {
    case cardNumber, expDate, cvv, holderName
}

/// What the form knows about one field. `wasBlurred` turns true the first time the field loses
/// focus and stays true.
public struct CardFieldState: Sendable, Equatable {
    public var isValid = false
    public var isFocused = false
    public var hasContent = false
    public var wasBlurred = false
}

/// Drives the Secure Fields card form for one payment item. Mount a ``CardFormView`` (or the
/// ``fieldViews``), observe ``isFormValid``, call ``submit()``.
@MainActor
public final class CardCoordinator: NSObject, ObservableObject, SecureFieldsDelegate {

    /// Which form a payment item needs, decided by the saved token behind it.
    public enum Mode: Sendable, Equatable {
        case freshCard
        /// A saved card whose PSP wants the cryptogram → a CVV-only form.
        case tokenCVV
        case tokenNoCVV

        public var rendersForm: Bool { self != .tokenNoCVV }

        public static func of(_ token: PayToken?) -> Mode {
            guard let token else { return .freshCard }
            return token.requiresCVV ? .tokenCVV : .tokenNoCVV
        }
    }

    public let mode: Mode

    /// A form that renders nothing starts valid.
    @Published public private(set) var isFormValid: Bool

    @Published public private(set) var detectedBrands: [CardBrand] = []

    /// The scheme the card will be tokenized under: the shopper's pick on a co-badged card, else
    /// the auto-selected one. Change it with ``selectBrand(_:)``.
    @Published public private(set) var selectedBrand: CardBrand?

    /// Per-field state, refreshed on every content or focus change.
    @Published public private(set) var fieldStates: [CardField: CardFieldState] = [:]

    /// `true` when the last BIN lookup failed — `detectedBrands` is then stale, not "no brand".
    /// Cleared by the next successful lookup.
    @Published public private(set) var binLookupFailed = false

    /// Label / helper / error copy per field, SDK defaults filled in.
    let texts: [CardField: ResolvedFieldTexts]
    let theme: PurseTheme.Resolved

    private let manager: SecureFieldsManager?
    /// Strong: nothing else retains a `host(for:)`-produced adapter, so a weak reference would go
    /// nil as soon as the caller's local did, silently no-oping `setCollected`/`setFulfilled`.
    private let host: any PluginHost
    private var pending: CheckedContinuation<CardTokenization, any Error>?

    public init(
        host: any PluginHost,
        tenantId: String,
        supportedBrands: [CardBrand],
        token: PayToken? = nil,
        options: PluginOptions = PluginOptions()
    ) {
        self.host = host
        self.mode = Mode.of(token)
        self.isFormValid = !mode.rendersForm
        let copy = options.cardFormTexts.resolved(locale: options.locale)
        self.texts = copy
        let resolved = (options.theme ?? .default).resolve()
        self.theme = resolved

        if mode.rendersForm {
            // A CVV-only form has no PAN to BIN-detect, so the saved token's own scheme comes first.
            let brands: [CardBrand] = {
                if let network = token?.selectedNetwork, let brand = CardBrand(rawValue: network) {
                    return [brand]
                }
                return supportedBrands.isEmpty ? [.visa, .mastercard, .carteBancaire] : supportedBrands
            }()

            let texts = options.cardFormTexts
            let style = SecureFieldsStyle(
                font: resolved.input.font ?? .systemFont(ofSize: 16),
                textColor: resolved.input.color ?? .label,
                placeholderColor: resolved.input.placeholderColor ?? .placeholderText,
                backgroundColor: resolved.input.backgroundColor,
                focus: Self.stateStyle(resolved.inputFocus),
                valid: Self.stateStyle(resolved.inputValid),
                invalid: Self.stateStyle(resolved.inputInvalid)
            )

            let config = SecureFieldsConfig(
                tenantId: tenantId,
                environment: host.environment.vaultEnvironment,
                brands: brands.compactMap(\.secureFieldsBrand),
                // Secure Fields renders the co-badge chips itself; off, a CB/Mastercard card
                // cannot be arbitrated at all.
                brandSelector: mode == .freshCard,
                style: style,
                // The field subset *is* how CVV-only is expressed — there is no flag. With no PAN
                // mounted, Secure Fields omits the `card` object and the Vault reads a CVV-only
                // submission (purse-securefields-ios >= 1.8.0).
                fields: mode == .tokenCVV
                    ? SecureFieldsFieldsConfig(cvv: Self.fieldConfig(texts.cvv, copy[.cvv]))
                    : SecureFieldsFieldsConfig(
                        pan: Self.fieldConfig(texts.cardNumber, copy[.cardNumber]),
                        expDate: Self.fieldConfig(texts.expDate, copy[.expDate]),
                        holderName: Self.fieldConfig(texts.holderName, copy[.holderName]),
                        cvv: Self.fieldConfig(texts.cvv, copy[.cvv])
                    )
            )
            let manager = SecureFieldsManager(config: config)
            manager.panContainer.panFieldAccessibilityIdentifier = CardField.cardNumber.accessibilityIdentifier
            manager.expDateView.accessibilityIdentifier = CardField.expDate.accessibilityIdentifier
            manager.cvvView.accessibilityIdentifier = CardField.cvv.accessibilityIdentifier
            manager.holderNameView.accessibilityIdentifier = CardField.holderName.accessibilityIdentifier
            self.manager = manager
        } else {
            self.manager = nil
        }

        super.init()
        manager?.delegate = self

        // An empty form is never payable.
        host.setFulfilled(!mode.rendersForm)
    }

    /// In display order. They size themselves: do not constrain their height.
    public var fieldViews: [UIView] {
        guard let manager else { return [] }
        return fields.map { field in
            switch field {
            case .cardNumber: manager.panContainer
            case .expDate: manager.expDateView
            case .cvv: manager.cvvView
            case .holderName: manager.holderNameView
            }
        }
    }

    /// The fields ``fieldViews`` holds, in the same order.
    public var fields: [CardField] {
        switch mode {
        case .freshCard: [.cardNumber, .expDate, .cvv, .holderName]
        case .tokenCVV: [.cvv]
        case .tokenNoCVV: []
        }
    }

    /// Tokenize the form and stash the result on the checkout. Does **not** pay: call
    /// `checkout.submitPayment()` next, or use `paymentElement`, which does both. A mode that
    /// renders no form has nothing to tokenize and returns immediately.
    @discardableResult
    public func submit(saveToken: Bool = false) async throws -> CardTokenization? {
        guard let manager, mode.rendersForm else { return nil }
        // Secure Fields' `submit()` returns early while already submitting, with no delegate
        // callback, so a second call overwriting `pending` would strand the first continuation.
        guard pending == nil else {
            throw PartnerUIError("a card tokenization is already in flight")
        }

        let tokenization: CardTokenization = try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            manager.submit(saveToken: saveToken)
        }

        apply(tokenization)
        return tokenization
    }

    /// The error ``CardFormView`` shows under `field` right now, or `nil` — for a host that draws
    /// its own form.
    public func errorMessage(for field: CardField) -> String? {
        texts[field]?.error(for: fieldStates[field] ?? CardFieldState())
    }

    /// Pick the scheme on a co-badged card, as a chip tap would. Ignored unless the BIN lookup
    /// detected `brand`.
    public func selectBrand(_ brand: CardBrand) {
        guard let brand = brand.secureFieldsBrand else { return }
        manager?.selectBrand(brand)
    }

    /// Stash the vault token for `/validate` and re-arm the fulfilment gate.
    func apply(_ tokenization: CardTokenization) {
        var collected: [String: JSONValue] = [
            CardPlugin.Collected.token: .string(tokenization.vaultFormToken),
        ]
        if let bin = tokenization.bin { collected[CardPlugin.Collected.bin] = .string(bin) }
        if let network = tokenization.selectedNetwork {
            collected[CardPlugin.Collected.network] = .string(network.wireValue)
        }
        host.setCollected(collected)
        isFormValid = true
        host.setFulfilled(true)
    }

    // MARK: SecureFieldsDelegate
    //
    // Every callback arrives on the main thread — the SDK hops through `DispatchQueue.main.async`
    // itself, and the rest fire from UIKit event paths — which is what makes `assumeIsolated` sound.
    // Each converts to our own types here, before anything crosses to the main actor.

    public nonisolated func secureFieldsDidTokenize(_ result: TokenizationResult) {
        let tokenization = CardTokenization(
            vaultFormToken: result.vaultFormToken,
            bin: result.bin,
            lastFourDigits: result.lastFourDigits,
            selectedNetwork: result.selectedNetwork.flatMap { CardBrand.fromSecureFields($0) }
        )
        MainActor.assumeIsolated { resume(.success(tokenization)) }
    }

    public nonisolated func secureFieldsDidFail(_ error: SecureFieldsError) {
        let message = String(describing: error)
        MainActor.assumeIsolated {
            // Not `message`: a vault API error is free text, and monitoring carries the reason.
            host.dispatch(.clientError(message: "card tokenization failed"))
            resume(.failure(PartnerUIError("card tokenization failed: \(message)")))
        }
    }

    public nonisolated func secureFieldsFormValidityChanged(_ isValid: Bool) {
        MainActor.assumeIsolated {
            isFormValid = isValid
            host.setFulfilled(isValid)
        }
    }

    public nonisolated func secureFieldsBrandsDetected(_ brands: [PurseSecureFields.CardBrand]) {
        let mapped = brands.compactMap { CardBrand.fromSecureFields($0) }
        MainActor.assumeIsolated {
            detectedBrands = mapped
            binLookupFailed = false
            refresh()
        }
    }

    public nonisolated func secureFieldsBrandSelected(_ brand: PurseSecureFields.CardBrand) {
        MainActor.assumeIsolated { refresh() }
    }

    public nonisolated func secureFieldsContentChanged() {
        MainActor.assumeIsolated { refresh() }
    }

    public nonisolated func secureFieldsFocusChanged(field: SecureField, isFocused: Bool) {
        let changed = CardField(field)
        MainActor.assumeIsolated {
            if !isFocused, let changed { fieldStates[changed, default: CardFieldState()].wasBlurred = true }
            refresh()
        }
    }

    public nonisolated func secureFieldsBinLookupFailed(_ error: SecureFieldsError) {
        MainActor.assumeIsolated { binLookupFailed = true }
    }

    /// Re-read what the manager knows. `wasBlurred` is ours alone — Secure Fields tracks no such thing.
    private func refresh() {
        guard let manager else { return }
        selectedBrand = manager.selectedBrand.flatMap { CardBrand.fromSecureFields($0) }
        for field in CardField.allCases where manager.configuredFields.contains(field.secureField) {
            var state = fieldStates[field, default: CardFieldState()]
            state.isValid = manager.isFieldValid(field.secureField)
            state.isFocused = manager.isFieldFocused(field.secureField)
            state.hasContent = manager.hasFieldContent(field.secureField)
            fieldStates[field] = state
        }
    }

    private func resume(_ result: Result<CardTokenization, any Error>) {
        pending?.resume(with: result)
        pending = nil
    }

    private static func fieldConfig(_ texts: CardFormTexts.FieldTexts, _ copy: ResolvedFieldTexts?) -> SecureFieldConfig {
        SecureFieldConfig(placeholder: texts.placeholder, accessibilityLabel: copy?.label)
    }

    /// `nil` when the theme leaves that state at the base style, so Secure Fields' own inheritance
    /// applies instead of an all-nil override object.
    private static func stateStyle(_ style: PurseTheme.FieldStyle) -> SecureFieldsStyle.StateStyle? {
        guard style.color != nil || style.backgroundColor != nil else { return nil }
        return SecureFieldsStyle.StateStyle(textColor: style.color, backgroundColor: style.backgroundColor)
    }
}

// MARK: - Vocabulary mapping

extension PurseEnvironment {
    /// The vault tier for this Payment API tier (development has no vault of its own). A mismatch
    /// fails tokenization with "no tenant with id was found", which names no environment.
    var vaultEnvironment: VaultEnvironment {
        switch self {
        case .production: .production
        case .sandbox, .development: .sandbox
        case .test: .test
        }
    }
}

extension CardField {
    /// Our field names vs Secure Fields' `SecureField`: `cardNumber` is its `pan`.
    init?(_ field: SecureField) {
        switch field {
        case .pan: self = .cardNumber
        case .expDate: self = .expDate
        case .cvv: self = .cvv
        case .holderName: self = .holderName
        @unknown default: return nil
        }
    }

    var secureField: SecureField {
        switch self {
        case .cardNumber: .pan
        case .expDate: .expDate
        case .cvv: .cvv
        case .holderName: .holderName
        }
    }

    /// Stable UI-test handle set on each field view.
    public var accessibilityIdentifier: String {
        switch self {
        case .cardNumber: "purse_card_number"
        case .expDate: "purse_card_exp_date"
        case .cvv: "purse_card_cvv"
        case .holderName: "purse_card_holder_name"
        }
    }
}

extension CardBrand {
    /// Secure Fields' vocabulary is not the Payment API's (`AMEX` vs `AMERICAN_EXPRESS`, no
    /// `DISCOVER`/`UNIONPAY`/`JCB`), so the mapping is explicit, never a raw-value cast.
    var secureFieldsBrand: PurseSecureFields.CardBrand? {
        switch self {
        case .visa: .visa
        case .mastercard: .mastercard
        case .americanExpress: .amex
        case .maestro: .maestro
        case .carteBancaire: .carteBancaire
        case .oney: .oney
        case .dinersClub, .discover, .unionPay, .jcb, .unknown: nil
        }
    }

    static func fromSecureFields(_ brand: PurseSecureFields.CardBrand) -> CardBrand? {
        switch brand {
        case .visa: .visa
        case .mastercard: .mastercard
        case .amex: .americanExpress
        case .maestro: .maestro
        case .carteBancaire: .carteBancaire
        case .oney: .oney
        @unknown default: nil
        }
    }
}
