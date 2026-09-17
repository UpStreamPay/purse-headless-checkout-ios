import Foundation
import Testing
@testable import PurseCheckoutApplePay
@testable import PurseCheckoutKlarna
@testable import PurseCheckoutPayPal
@testable import PurseHeadlessCheckout

/// What each partner module's surface decides before any partner SDK is touched — the credential-
/// substitution branches, which are pure logic and need no credentials to test.
@MainActor
@Suite(.serialized)
struct PartnerSurfaceTests {

    private static let host = "api.purse-surface.example"

    private final class Spy: PaymentElementListener {
        var outcomes: [PaymentOutcome] = []
        var readies: [Bool] = []
        func onOutcome(_ outcome: PaymentOutcome) { outcomes.append(outcome) }
        func onReady(_ ready: Bool) { readies.append(ready) }
    }

    /// `protocols` carrying one card, one Apple Pay, one PayPal wallet and one redirection method.
    private func makeCheckout(_ modules: [any PartnerModule]) throws -> PurseHeadlessCheckout {
        let registry = PluginRegistry()
        modules.forEach(registry.install)
        let protocols: [String: Any] = [
            "purse": ["creditcard": ["configurations": [
                "stable": true, "labels": [],
                "vault": ["vendor": "purse", "supported_brands": ["VISA"]], "settings": [:],
            ]]],
            "adyen": ["applepay": ["configurations": [
                "stable": true, "labels": [], "settings": [:],
            ]]],
            "paypal": ["wallet": ["configurations": [
                "stable": true, "labels": [], "settings": ["merchant_specifics": ["client_id": "cid"]],
            ]]],
            "axepta": ["wero": ["configurations": [
                "stable": true, "labels": [], "template": "redirection", "settings": [:],
            ]]],
        ]
        return try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(
                apiURL: "https://\(Self.host)/payment/v1",
                paymentSession: TestSessions.paymentSession(
                    id: "partner-surface-session", amount: 100, protocols: protocols
                )
            ),
            registry: registry,
            urlSession: StubURLProtocol.session()
        )
    }

    private func item(_ checkout: PurseHeadlessCheckout, _ id: String) throws -> PaymentItem {
        try #require(checkout.paymentMethods.first { $0.id == id })
    }

    private func failureMessage(_ outcomes: [PaymentOutcome]) -> String? {
        guard case let .failed(error) = outcomes.first else { return nil }
        return error.message
    }

    /// Apple Pay's merchant id is entitlement-bound and in no session, so a module installed
    /// without one still registers the plugin; only the element refuses.
    @Test func applePayWithoutAMerchantIdRefusesAndSaysWhy() async throws {
        StubURLProtocol.reset(host: Self.host)
        let checkout = try makeCheckout([ApplePayModule()])
        let spy = Spy()

        let element = checkout.paymentElement(for: try item(checkout, "adyen-applepay"), listener: spy)
        #expect(element.hasUI == false)
        await element.submit().value

        #expect(failureMessage(spy.outcomes)?.contains("merchant id") == true)
        #expect(StubURLProtocol.paths(host: Self.host).isEmpty)
    }

    /// Android defaults Klarna's return URL to `"{packageName}.klarna://return"`. iOS has no
    /// applicationId to build one from, so an absent URL is reported rather than guessed.
    @Test func klarnaWithoutAReturnURLRefusesAndSaysWhy() async throws {
        StubURLProtocol.reset(host: Self.host)
        // This session does not offer `(klarna, installments)`, so drive the module directly.
        let checkout = try makeCheckout([KlarnaModule()])
        let spy = Spy()
        let host = try checkout.host(for: {
            guard case let .primaryMethod(method) = try item(checkout, "purse-creditcard") else {
                fatalError("the session's card is not a primary method")
            }
            return method
        }())

        let request = SurfaceRequest(
            host: host,
            isToken: false,
            key: "k:0",
            listener: spy,
            appReturnURL: nil,
            redirectPresenter: nil,
            capture: {}
        )
        let surface = try #require(KlarnaModule().surface(for: KlarnaPlugin(partner: .klarna), request: request))

        #expect(surface.hasUI == false)
        await surface.submit()
        #expect(failureMessage(spy.outcomes)?.contains("return URL") == true)
    }

    /// A saved PayPal account needs no approval and no button — it pays from the host's own Pay
    /// button like any other no-form token, so the surface must not be self-submitting.
    @Test func aSavedPayPalAccountRendersNoButton() async throws {
        StubURLProtocol.reset(host: Self.host)
        let checkout = try makeCheckout([PayPalModule()])
        let spy = Spy()
        guard case let .primaryMethod(method) = try item(checkout, "paypal-wallet") else {
            Issue.record("expected a primary method")
            return
        }
        let host = try checkout.host(for: method)

        func surface(isToken: Bool) throws -> PaymentSurface {
            let request = SurfaceRequest(
                host: host, isToken: isToken, key: "p:0", listener: spy,
                appReturnURL: nil, redirectPresenter: nil, capture: {}
            )
            return try #require(PayPalModule().surface(for: PayPalPlugin(partner: .paypal), request: request))
        }

        #expect(try surface(isToken: true).hasUI == false)
        #expect(try surface(isToken: true).selfSubmitting == false)
        // A fresh PayPal method still renders its own branded button and pays from its tap.
        #expect(try surface(isToken: false).selfSubmitting)
    }

    /// The PSP's own hosted page is the payment step: nothing to render, and ready as soon as it
    /// exists because `/init` runs inside `preValidation`.
    @Test func aRedirectionMethodRendersNothingAndIsReadyOnPrepare() async throws {
        StubURLProtocol.reset(host: Self.host)
        let checkout = try makeCheckout([])
        let spy = Spy()

        let element = checkout.paymentElement(for: try item(checkout, "axepta-wero"), listener: spy)
        #expect(element.hasUI == false)
        await element.prepare()

        #expect(element.isReady)
        #expect(spy.readies == [true])
        #expect(StubURLProtocol.paths(host: Self.host).isEmpty)
    }
}
