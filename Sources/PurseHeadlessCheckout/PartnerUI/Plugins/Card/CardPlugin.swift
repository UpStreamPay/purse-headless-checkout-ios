// Web: packages/partner-ui/src/plugins/vaults/purse/creditcard + generics/hostedfields
// Same: token from the vault into /validate with `partner_data.browser`; saved token + CVV-only token side by side; no /init (`skipInit`) except for cybersource (`vaultExtras.skipInit: false`).
// Differs: cybersource's /init runs inside `preValidation`, not at `onSessionSet` (nothing about rendering depends on it — Secure Fields tokenizes independently); a skipped /init omits `step_id` where web sends `null`, as Android does.

import Combine
import Foundation
import PurseSecureFields
import UIKit

/// The protocol half of the `purse`-vendor card plugin. The form and tokenization live in
/// ``CardCoordinator``.
public struct CardPlugin: PartnerUIPlugin {

    /// Keys ``CardCoordinator`` uses when handing its result back to the checkout.
    public enum Collected {
        public static let token = "cardVaultToken"
        public static let bin = "cardBin"
        public static let network = "selected_network"
    }

    static let vaultVendor = "purse"

    /// Web's `vaultExtras` with `skipInit: false`: cybersource's `/init` flags the transaction as
    /// vault mode. Every other PSP takes `/validate` with no `/init` — worldpay refuses one.
    static let partnersRequiringInit: Set<String> = ["cybersource"]

    public let partner: Partner
    public let method: PaymentMethod = .creditCard

    public init(partner: Partner) {
        self.partner = partner
    }

    /// The headless half of web's `validateUi`. The coordinator refuses to tokenize an invalid
    /// form, so a vault token is proof enough.
    public func validateUI(_ context: PartnerUIContext) async throws -> Bool {
        if let token = context.token, !token.requiresCVV { return true }
        return context.collected[Collected.token]?.stringValue != nil
    }

    public func preValidation(_ context: PartnerUIContext) async throws -> ValidateItemPayload {
        let partnerData: [String: JSONValue] = [
            "browser": .object(await BrowserData.make(locale: context.options.locale)),
        ]
        var stepId: Int?
        if Self.partnersRequiringInit.contains(partner.wireValue) {
            let initResponse = try await context.api.initPayment([
                "partner": .string(partner.wireValue),
                "method": .string(method.wireValue),
                "amount": .number(context.amount.description),
                "partner_data": .object(partnerData),
                "payment_data": .object(["vault_vendor": .string(Self.vaultVendor)]),
                "payment_preferences": .object([:]),
            ])
            stepId = try parseInit(initResponse)
        }

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
                paymentData: paymentData,
                partnerData: partnerData
            )
        }

        guard let vaultVendorTokenId = context.collected[Collected.token]?.stringValue else {
            throw PartnerUIError("card vault token missing — tokenize with Secure Fields before submitting")
        }

        // `vault_vendor_token_id` is top-level, **not** nested under `card`; `card` carries only the
        // non-sensitive metadata the vault echoed back.
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
            ],
            partnerData: partnerData
        )
    }

    /// `/init`'s `step_id`, or a throw when the init was refused.
    private func parseInit(_ response: JSONValue) throws -> Int? {
        let status = response["status"]
        if let state = status?["state"]?.stringValue, !state.isEmpty, state != "SUCCESS" {
            throw PaymentAPIError(
                "creditcard init not successful (state=\(state))",
                path: "/init"
            )
        }
        return response["step_id"]?.intValue
    }
}

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
        let observer = CardReadinessObserver(coordinator: coordinator, listener: listener)

        return PaymentSurface(
            hasUI: coordinator.mode.rendersForm,
            selfSubmitting: false,
            makeView: {
                guard coordinator.mode.rendersForm else { return nil }
                return CardFormView(coordinator: coordinator)
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
    /// `SecurePANContainer` ships its own 48pt rounded box; the CVV, expiry and holder-name views
    /// are bare fields with no height and no background, so they get a matching one here.
    @MainActor
    static func matchingPAN(_ view: UIView, theme: PurseTheme.Resolved) -> UIView {
        guard !(view is SecurePANContainer) else { return view }

        view.translatesAutoresizingMaskIntoConstraints = false
        let box = UIView()
        // `PurseTheme.default`'s `.clear` tells the *field* to paint nothing; it is not a colour for
        // the box around it.
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

/// The card form as the SDK renders it: per field, a label, the secure field, and a line for the
/// helper text or error (Android `PurseCardForm`). `paymentElement` mounts it for you; mount it
/// yourself when driving a ``CardCoordinator`` directly.
@MainActor
public final class CardFormView: UIStackView {
    private var cancellable: AnyCancellable?

    public init(coordinator: CardCoordinator) {
        let theme = coordinator.theme
        super.init(frame: .zero)
        axis = .vertical
        spacing = 12

        var rows: [(CardField, ResolvedFieldTexts, UILabel, UILabel)] = []
        for (field, view) in zip(coordinator.fields, coordinator.fieldViews) {
            guard let texts = coordinator.texts[field] else { continue }
            let label = UILabel()
            label.text = texts.label
            label.font = theme.label.font
            let message = UILabel()
            // ponytail: one line that shrinks to fit, because `PaymentElementView` measures the form
            // once and a message that wrapped later would be clipped. Wrap instead once the view
            // re-measures on content change.
            message.numberOfLines = 1
            message.adjustsFontSizeToFitWidth = true
            message.minimumScaleFactor = 0.6
            message.font = theme.helperText.font
            message.text = " "
            let column = UIStackView(arrangedSubviews: [label, CardModule.matchingPAN(view, theme: theme), message])
            column.axis = .vertical
            column.spacing = 4
            addArrangedSubview(column)
            rows.append((field, texts, label, message))
        }

        cancellable = coordinator.$fieldStates.sink { states in
            for (field, texts, label, message) in rows {
                let state = states[field] ?? CardFieldState()
                let invalid = texts.error(for: state) != nil
                label.textColor = (invalid ? theme.labelInvalid.color : theme.label.color) ?? .label
                message.textColor = (invalid ? theme.helperTextInvalid.color : theme.helperText.color) ?? .secondaryLabel
                message.text = texts.message(for: state) ?? " "
            }
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
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
