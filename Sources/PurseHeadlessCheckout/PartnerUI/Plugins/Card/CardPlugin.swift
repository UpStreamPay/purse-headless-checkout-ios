// Web: packages/partner-ui/src/plugins/vaults/purse/creditcard + generics/hostedfields
// Same: token from the vault into /validate; saved token + CVV-only token side by side.
// Differs: /init runs inside `preValidation`, not at `onSessionSet` (nothing about rendering depends on it — Secure Fields tokenizes independently).

import Combine
import Foundation
import PurseSecureFields
import UIKit

/// The `purse`-vendor vault-backed card plugin — the protocol half, with no Secure Fields types in
/// sight. The interactive half (the form, tokenization) lives in ``CardCoordinator``.
public struct CardPlugin: PartnerUIPlugin {

    /// Keys ``CardCoordinator`` uses when handing its result back to the checkout.
    public enum Collected {
        public static let token = "cardVaultToken"
        public static let bin = "cardBin"
        public static let network = "selected_network"
    }

    static let vaultVendor = "purse"

    public let partner: Partner
    public let method: PaymentMethod = .creditCard

    public init(partner: Partner) {
        self.partner = partner
    }

    /// The headless half of web's `validateUi`. The form itself lives in the coordinator, which
    /// refuses to tokenize an invalid one, so all this can check is the outcome: a vault token
    /// means the form was submitted successfully.
    public func validateUI(_ context: PartnerUIContext) async throws -> Bool {
        if let token = context.token, !token.requiresCVV { return true }
        return context.collected[Collected.token]?.stringValue != nil
    }

    public func preValidation(_ context: PartnerUIContext) async throws -> ValidateItemPayload {
        let initResponse = try await context.api.initPayment([
            "partner": .string(partner.wireValue),
            "method": .string(method.wireValue),
            "amount": .number(context.amount.description),
            "partner_data": .object([:]),
            "payment_data": .object(["vault_vendor": .string(Self.vaultVendor)]),
            "payment_preferences": .object([:]),
        ])
        let stepId = try parseInit(initResponse)

        // A saved card: the opaque token value plus its metadata travels straight into
        // payment_data.
        if let token = context.token {
            var paymentData = token.patch()
            paymentData["vault_vendor"] = .string(Self.vaultVendor)

            if token.requiresCVV {
                guard let cvvVaultToken = context.collected[Collected.token]?.stringValue else {
                    throw PartnerUIError(
                        "CVV vault token missing — collect the CVV with Secure Fields before submitting"
                    )
                }
                paymentData["vault_vendor_token_id"] = .string(cvvVaultToken)
            }

            return ItemPayload(
                partner: partner,
                method: method,
                amount: context.amount,
                stepId: stepId,
                paymentData: paymentData
            )
        }

        guard let vaultVendorTokenId = context.collected[Collected.token]?.stringValue else {
            throw PartnerUIError("card vault token missing — tokenize with Secure Fields before submitting")
        }

        // `vault_vendor_token_id` is a **top-level field, not nested under `card`**. `card` carries
        // only the non-sensitive metadata the vault echoed back.
        var card: [String: JSONValue] = [:]
        if let bin = context.collected[Collected.bin]?.stringValue?.nonBlank {
            card["bin"] = .string(bin)
        }
        if let network = context.collected[Collected.network]?.stringValue?.nonBlank {
            card["selected_network"] = .string(network)
        }

        return ItemPayload(
            partner: partner,
            method: method,
            amount: context.amount,
            stepId: stepId,
            paymentData: [
                "card": .object(card),
                "vault_vendor_token_id": .string(vaultVendorTokenId),
                "vault_vendor": .string(Self.vaultVendor),
            ]
        )
    }

    /// `/init`'s `step_id`, or a thrown error when the init itself was refused.
    private func parseInit(_ response: JSONValue) throws -> Int? {
        let status = response["status"]
        if let state = status?["state"]?.stringValue, !state.isEmpty, state != "SUCCESS" {
            let description = status?["description"]?.stringValue ?? ""
            throw PaymentAPIError(
                "creditcard init not successful (state=\(state)) \(description)"
                    .trimmingCharacters(in: .whitespaces),
                path: "/init"
            )
        }
        return response["step_id"]?.intValue
    }
}

/// Registers the Purse-vault card plugin for every method whose `vault.vendor` is `purse`.
/// Built in — a merchant never installs this one.
struct CardModule: PartnerModule {
    let id = "purse.card"

    @MainActor func register(into registry: PluginRegistry) {
        registry.registerVault(vendor: .purse) { CardPlugin(partner: $0.partner) }
    }

    @MainActor func renders(_ plugin: any PartnerUIPlugin) -> Bool { plugin is CardPlugin }

    @MainActor func surface(for plugin: any PartnerUIPlugin, request: SurfaceRequest) -> PaymentSurface? {
        let context = request.host.buildContext()
        let coordinator = CardCoordinator(
            host: request.host,
            tenantId: context.vaultTenantId ?? "",
            supportedBrands: context.configuration?.vault?.supportedBrands ?? [],
            token: context.token,
            options: context.options
        )
        let listener = request.listener
        // A form gates on its own validity; a no-CVV token has nothing to fill in, so it is ready
        // as soon as it exists.
        let observer = CardReadinessObserver(coordinator: coordinator, listener: listener)

        return PaymentSurface(
            hasUI: coordinator.mode.rendersForm,
            selfSubmitting: false,
            makeView: {
                guard coordinator.mode.rendersForm else { return nil }
                let theme = (context.options.theme ?? .default).resolve()
                let stack = UIStackView(
                    arrangedSubviews: coordinator.fieldViews.map { Self.matchingPAN($0, theme: theme) }
                )
                stack.axis = .vertical
                stack.spacing = 12
                return stack
            },
            prepare: { observer.start() },
            submit: {
                do {
                    _ = try await coordinator.submit()
                } catch {
                    listener.onOutcome(.failed(error.asPurseError()))
                    return
                }
                await request.captureNow()
            }
        )
    }
}

extension CardModule {
    /// The four field views do not arrive alike: `SecurePANContainer` ships its own chrome — a 48pt
    /// rounded `.secondarySystemBackground` box holding the PAN field and the brand selector —
    /// while the CVV, expiry and holder-name views are bare fields with no height and no background
    @MainActor
    static func matchingPAN(_ view: UIView, theme: PurseTheme.Resolved) -> UIView {
        guard !(view is SecurePANContainer) else { return view }

        view.translatesAutoresizingMaskIntoConstraints = false
        let box = UIView()
        // `PurseTheme.default` sets `input.backgroundColor` to `.clear`, which is an instruction to
        // the *field* to paint nothing — not a colour for the box around it.
        let themed = theme.input.backgroundColor
        box.backgroundColor = (themed?.cgColor.alpha ?? 0) > 0 ? themed : .secondarySystemBackground
        box.layer.cornerRadius = 10
        box.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            view.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            view.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            view.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
            box.heightAnchor.constraint(equalToConstant: 48),
        ])
        return box
    }
}

/// Bridges `CardCoordinator.$isFormValid` onto the element listener. A no-CVV token renders no form
/// and never publishes, so its readiness is asserted once instead.
@MainActor
private final class CardReadinessObserver {
    private let coordinator: CardCoordinator
    private let listener: any PaymentElementListener
    private var cancellable: AnyCancellable?

    init(coordinator: CardCoordinator, listener: any PaymentElementListener) {
        self.coordinator = coordinator
        self.listener = listener
    }

    func start() {
        guard coordinator.mode.rendersForm else {
            listener.onReady(true)
            return
        }
        cancellable = coordinator.$isFormValid.sink { [listener] valid in
            listener.onReady(valid)
        }
    }
}
