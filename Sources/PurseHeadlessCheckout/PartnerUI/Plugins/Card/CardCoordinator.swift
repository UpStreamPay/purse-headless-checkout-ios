// Web: packages/partner-ui hosted fields mount + submitForResult
// Same: three modes (fresh card / saved card needing its CVV / saved card needing nothing); brands from the token's own scheme, then the vault's supported brands.
// Differs: Secure Fields is a Swift 5 module, so nothing it owns crosses an isolation boundary — see "Crossing the Swift 5 boundary" in AGENTS.md.

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

/// Drives the Secure Fields card form for one payment item. Mount its ``fieldViews``, observe
/// ``isFormValid``, call ``submit()``.
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

        if mode.rendersForm {
            // A CVV-only form has no PAN to BIN-detect, so the saved token's own scheme comes first.
            let brands: [CardBrand] = {
                if let network = token?.selectedNetwork, let brand = CardBrand(rawValue: network) {
                    return [brand]
                }
                return supportedBrands.isEmpty ? [.visa, .mastercard, .carteBancaire] : supportedBrands
            }()

            let resolved = (options.theme ?? .default).resolve()
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
                style: style,
                // The field subset *is* how CVV-only is expressed — there is no flag. With no PAN
                // mounted, Secure Fields omits the `card` object and the Vault reads a CVV-only
                // submission (purse-securefields-ios >= 1.8.0).
                fields: mode == .tokenCVV
                    ? SecureFieldsFieldsConfig(cvv: .init(placeholder: texts.cvv.placeholder))
                    : SecureFieldsFieldsConfig(
                        pan: .init(placeholder: texts.cardNumber.placeholder),
                        expDate: .init(placeholder: texts.expDate.placeholder),
                        holderName: .init(placeholder: texts.holderName.placeholder),
                        cvv: .init(placeholder: texts.cvv.placeholder)
                    )
            )
            self.manager = SecureFieldsManager(config: config)
        } else {
            self.manager = nil
        }

        super.init()
        manager?.delegate = self

        // An empty form is never payable.
        host.setFulfilled(!mode.rendersForm)
    }

    /// In display order.
    public var fieldViews: [UIView] {
        guard let manager else { return [] }
        switch mode {
        case .freshCard:
            return [manager.panContainer, manager.expDateView, manager.cvvView, manager.holderNameView]
        case .tokenCVV:
            return [manager.cvvView]
        case .tokenNoCVV:
            return []
        }
    }

    /// Tokenize the form and stash the result on the checkout. A mode that renders no form has
    /// nothing to tokenize and returns immediately.
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
        MainActor.assumeIsolated { detectedBrands = mapped }
    }

    private func resume(_ result: Result<CardTokenization, any Error>) {
        pending?.resume(with: result)
        pending = nil
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
