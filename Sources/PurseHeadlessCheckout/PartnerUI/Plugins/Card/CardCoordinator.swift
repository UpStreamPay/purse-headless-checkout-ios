// Web: packages/partner-ui hosted fields mount + submitForResult
// Same: three modes (fresh card / saved card needing its CVV / saved card needing nothing), brand list from the token's own scheme then the vault's supported brands.
// Differs: Secure Fields is a Swift 5 module, so nothing it owns crosses an isolation boundary — see "Crossing the Swift 5 boundary" in AGENTS.md.

import Foundation
import PurseSecureFields
import UIKit

/// What a tokenization produced, as **our** `Sendable` type. Secure Fields' `TokenizationResult` is
/// a public struct in a Swift 5 module, so it is not `Sendable` to us and cannot cross an isolation
/// boundary — and a dependency's types have no business in our own surface regardless.
public struct CardTokenization: Sendable, Equatable {
    public let vaultFormToken: String
    /// Both `nil` after a CVV-only tokenization: the vault stored a cryptogram against a card it
    /// already knows, so the response carries no `card` block.
    public let bin: String?
    public let lastFourDigits: String?
    /// The network actually submitted, in **Payment API** vocabulary; `nil` on a CVV-only form.
    public let selectedNetwork: CardBrand?
}

/// Drives the Secure Fields card form for one payment item. Mount its ``fieldViews`` in your own
/// layout, observe ``isFormValid``, and call ``submit()``.
@MainActor
public final class CardCoordinator: NSObject, ObservableObject, SecureFieldsDelegate {

    /// Which form a payment item needs, decided by the saved token behind it.
    public enum Mode: Sendable, Equatable {
        /// PAN / expiry / CVV / holder, tokenized on submit.
        case freshCard
        /// A saved card whose PSP wants the cryptogram → a CVV-only form.
        case tokenCVV
        /// A saved card that pays with no form at all.
        case tokenNoCVV

        public var rendersForm: Bool { self != .tokenNoCVV }

        public static func of(_ token: PayToken?) -> Mode {
            guard let token else { return .freshCard }
            return token.requiresCVV ? .tokenCVV : .tokenNoCVV
        }
    }

    public let mode: Mode

    /// `true` once the form is complete enough to submit. A form that renders nothing starts valid.
    @Published public private(set) var isFormValid: Bool

    /// The card schemes the form offers.
    @Published public private(set) var detectedBrands: [CardBrand] = []

    private let manager: SecureFieldsManager?
    /// Strong, like every other coordinator's: nothing else retains a `host(for:)`-produced
    /// adapter, so a weak reference would go nil the moment the caller's local went out of
    /// scope — silently turning `setCollected`/`setFulfilled` into no-ops right after `init`.
    private let host: any PluginHost
    private var pending: CheckedContinuation<CardTokenization, any Error>?

    /// - Parameters: - host: the seam back to the checkout — where the vault token is stashed and
    /// fulfilment reported. - tenantId: `vault.vendor_front_data.purse.tenant_id` from the session.
    /// - supportedBrands: the method's `vault.supported_brands`.
    public init(
        host: any PluginHost,
        tenantId: String,
        supportedBrands: [CardBrand],
        token: PayToken? = nil
    ) {
        self.host = host
        self.mode = Mode.of(token)
        self.isFormValid = !mode.rendersForm

        if mode.rendersForm {
            // A CVV-only form has no PAN to BIN-detect, so the saved token's own scheme comes first;
            // then the method's supported brands; then a sane default.
            let brands: [CardBrand] = {
                if let network = token?.selectedNetwork, let brand = CardBrand(rawValue: network) {
                    return [brand]
                }
                return supportedBrands.isEmpty ? [.visa, .mastercard, .carteBancaire] : supportedBrands
            }()

            let config = SecureFieldsConfig(
                tenantId: tenantId,
                environment: host.environment.vaultEnvironment,
                brands: brands.compactMap(\.secureFieldsBrand),
                // Field subset *is* how CVV-only is expressed — there is no flag. With no PAN field
                // mounted, Secure Fields omits the `card` object, which the Vault reads as a
                // CVV-only submission (purse-securefields-ios >= 1.8.0).
                fields: mode == .tokenCVV ? .cvvOnly : .all
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

    /// The field views to mount, in display order. Empty when the mode renders no form.
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

    /// Tokenize the form and stash the result on the checkout, ready for the next submit.
    ///
    /// A mode that renders no form has nothing to tokenize and returns immediately.
    @discardableResult
    public func submit(saveToken: Bool = false) async throws -> CardTokenization? {
        guard let manager, mode.rendersForm else { return nil }
        // Secure Fields' own `submit()` opens with `guard !isSubmitting else { return }` and comes
        // back with **no delegate callback at all**, so a second call that overwrote `pending`
        // would strand the first continuation for the life of the process (`SWIFT TASK CONTINUATION
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

    /// What a successful tokenization does to the checkout: stash the vault token for `/validate`,
    /// and **re-arm the fulfilment gate**.
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
    // Every callback arrives on the main thread: the SDK hops through `DispatchQueue.main.async`
    // itself before touching the delegate, and the rest fire from UIKit event paths. That is what
    // makes `assumeIsolated` an assertion of something true rather than a wish. Each one converts
    // to our own types *here*, before anything crosses to the main actor.

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
}

// MARK: - Vocabulary mapping

extension PurseEnvironment {
    /// The vault tier for this Payment API tier. Development has no vault of its own. Each tier's
    /// tenants exist only in its own vault, so a mismatch fails tokenization with "no tenant with
    /// id was found" rather than anything that names the environment.
    var vaultEnvironment: VaultEnvironment {
        switch self {
        case .production: .production
        case .sandbox, .development: .sandbox
        case .test: .test
        }
    }
}

extension CardBrand {
    /// Secure Fields' brand vocabulary is **not** the Payment API's: it says `AMEX` where the
    /// session says `AMERICAN_EXPRESS`, and carries no `DISCOVER`/`UNIONPAY`/`JCB`. Mapping is
    /// explicit in both directions, never a raw-value cast.
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
