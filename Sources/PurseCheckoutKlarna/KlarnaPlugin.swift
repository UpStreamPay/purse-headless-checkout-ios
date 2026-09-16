// Web: packages/partner-ui/src/plugins/partners/klarna-installments/index.ts
// Same: /init; /validate carries only the step_id; Klarna's own authorize() runs in postValidation, only after /validate succeeds — one submit both pays and opens Klarna's step.
// Differs: the live authorize callback can't travel through `collected` (wire-safe JSONValue only, no closures, unlike Android's untyped `collected: Map<String, Any>`). KlarnaCoordinator registers the closure in KlarnaAuthorizationRegistry, keyed by a token stashed in `collected` instead of the closure itself.

import Foundation
import UIKit
import PurseHeadlessCheckout

/// Thrown by ``KlarnaPlugin/postValidation(_:context:)`` when the shopper declined Klarna's own
/// authorization — distinct from ``PartnerUIError`` so ``KlarnaCoordinator`` can report it as a
/// cancellation rather than a failure, the same distinction Android's `KlarnaAuthorizationDeclined`
public struct KlarnaAuthorizationDeclined: PurseError {
    public var code: PurseErrorCode { .partnerUIError }
    public var message: String { "Klarna declined to authorize" }
    public var underlying: (any Error)? { nil }
    public init() {}
}

/// The Klarna [PartnerUiPlugin] — the protocol half (pure, no Klarna SDK types).
public struct KlarnaPlugin: PartnerUIPlugin {

    /// Keys ``KlarnaCoordinator`` uses in `setCollected`.
    public enum Collected {
        /// The `/init` step id — threaded through to `/validate` unconditionally, same as Android
        /// (a missing one is the API's problem to reject, not this plugin's to guard).
        public static let stepId = "klarnaStepId"
        /// The token ``KlarnaAuthorizationRegistry`` uses to look up the live authorize callback.
        public static let authorizeToken = "klarnaAuthorizeToken"
    }

    public let partner: Partner
    public let method: PaymentMethod = .installments

    public init(partner: Partner) {
        self.partner = partner
    }

    public func preValidation(_ context: PartnerUIContext) async throws -> ValidateItemPayload {
        ItemPayload(
            partner: partner,
            method: method,
            amount: context.amount,
            stepId: context.collected[Collected.stepId]?.intValue
        )
    }

    /// Runs only once `/validate` itself succeeded (mirrors web's `executePayment`, which only
    /// calls `postValidateItems` when `global_status === SUCCESS`).
    public func postValidation(_ result: ValidationResult, context: PartnerUIContext) async throws {
        guard result.isSuccess else { return }
        guard let token = context.collected[Collected.authorizeToken]?.stringValue,
              let authorize = await KlarnaAuthorizationRegistry.shared.callback(for: token)
        else {
            throw PartnerUIError("Klarna authorize callback missing — was the widget ever prepared?")
        }
        guard try await authorize() else { throw KlarnaAuthorizationDeclined() }
    }
}

/// Builds the `/init` request body for a Klarna (`installments`) payment and parses its response —
/// ports web's dedicated `klarna-installments` plugin. Pure JSON — no Klarna SDK types here.
enum KlarnaRequestBuilder {

    /// `KlarnaPaymentView`'s `category` — the only category this plugin renders (web's `'klarna'`).
    static let paymentMethodCategory = "klarna"

    static func initPayload(amount: Decimal, partner: Partner) -> [String: JSONValue] {
        [
            "partner": .string(partner.wireValue),
            "method": .string(PaymentMethod.installments.wireValue),
            "amount": .number(amount.description),
            "partner_data": .object([:]),
            "payment_data": .object([:]),
            "payment_preferences": .object([:])
        ]
    }

    /// Parse the `/init` response into a ``KlarnaConfig`` — just the `klarna_client_token` off
    /// `plugin_result.logs`.
    static func parseInitConfig(_ response: JSONValue) throws -> KlarnaConfig {
        let state = response["status"]?["state"]?.stringValue ?? ""
        guard state.isEmpty || state == "SUCCESS" else {
            let description = response["status"]?["description"]?.stringValue ?? ""
            throw PaymentAPIError(
                "klarna init not successful (state=\(state)) \(description)"
                    .trimmingCharacters(in: .whitespaces),
                path: "/init"
            )
        }
        guard let clientToken = response["plugin_result"]?["logs"]?["klarna_client_token"]?.stringValue,
              !clientToken.isEmpty
        else {
            throw PartnerUIError("klarna init returned no klarna_client_token in logs")
        }
        return KlarnaConfig(clientToken: clientToken)
    }

    /// The top-level `step_id` `/init` returns for this item (web's `initData.step_id`).
    static func parseStepId(_ response: JSONValue) -> Int? {
        response["step_id"]?.intValue
    }
}

/// What the native widget needs from `/init`: the client token `KlarnaPaymentView.initialize` reads.
struct KlarnaConfig {
    let clientToken: String
}

/// Registers the Klarna installments plugin. Install this to offer Klarna:
public struct KlarnaModule: PartnerModule {
    public let id = "purse.klarna"

    public init() {}

    @MainActor public func register(into registry: PluginRegistry) {
        registry.register(partner: .klarna, method: .installments) { KlarnaPlugin(partner: $0.partner) }
    }

    @MainActor public func renders(_ plugin: any PartnerUIPlugin) -> Bool { plugin is KlarnaPlugin }

    @MainActor public func surface(
        for plugin: any PartnerUIPlugin,
        request: SurfaceRequest
    ) -> PaymentSurface? {
        let listener = request.listener
        // Klarna opens external banking and ID apps and returns through a deep link. Android
        // defaults it to `"{packageName}.klarna://return"`; iOS has no applicationId to build one
        // from, so an absent URL is reported rather than guessed.
        guard let returnURL = request.appReturnURL else {
            return .headless(submit: {
                listener.onOutcome(.failed(PartnerUIError(
                    "Klarna needs an app return URL: pass appReturnURL to paymentElement(for:…)"
                )))
            })
        }

        let coordinator = KlarnaCoordinator(host: request.host)
        let container = UIView()

        return PaymentSurface(
            hasUI: true,
            selfSubmitting: false,
            makeView: { container },
            prepare: {
                do {
                    try await coordinator.prepare(into: container, returnURL: returnURL)
                    listener.onReady(true)
                } catch {
                    listener.onReady(false)
                    listener.onOutcome(.failed(error.asPurseError()))
                }
            },
            // Klarna authorizes inside `postValidation`, so one `/validate` both pays and opens
            // Klarna's own step — there is no separate native call to make first.
            submit: { await request.captureNow() }
        )
    }
}
