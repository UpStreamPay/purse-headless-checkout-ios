import Foundation
import PassKit
import Testing
@testable import PurseCheckoutApplePay
@testable import PurseHeadlessCheckout

/// Apple Pay's server-driven configuration and its per-partner envelopes. The sheet itself needs a
/// real device and a provisioned merchant ID, so it is not unit tested — the same gap Android has
/// with its Play Services sheet.
@MainActor
struct ApplePayTests {

    // MARK: Variant selection

    /// The partner decides the envelope, and it comes from the session — which is why Apple Pay
    /// cannot be PSP-agnostic at the token level, and does not need to be.
    @Test func theVariantFollowsThePartner() {
        #expect(ApplePayVariant.of(.adyen) == .adyen)
        #expect(ApplePayVariant.of(.other("ingenico")) == .ingenico)
        #expect(ApplePayVariant.of(.other("anyone-else")) == .default)
        #expect(ApplePayVariant.of(.purse) == .default)
    }

    // MARK: Configuration comes from /init

    private func initResponse(_ logs: [String: JSONValue]) -> JSONValue {
        .object(["plugin_result": .object(["logs": .object(logs)])])
    }

    @Test func ingenicoReadsItsCamelCaseKeys() throws {
        let config = try ApplePayRequestConfiguration.from(
            initResponse: initResponse([
                "merchantName": "Shop",
                "countryCode": "FR",
                "currencyCode": "EUR",
                "merchantCapabilities": #"["supports3DS","supportsCredit"]"#,
                "productId": .number("302"),
            ]),
            variant: .ingenico,
            fallbackMerchantName: "fallback"
        )

        #expect(config.countryCode == "FR")
        #expect(config.currencyCode == "EUR")
        #expect(config.merchantName == "Shop")
        #expect(config.productId == "302")
        #expect(config.merchantCapabilities.contains(.threeDSecure))
        #expect(config.merchantCapabilities.contains(.credit))
    }

    /// Adyen uses snake_case for the same fields — a real difference, not a tidy-up opportunity.
    @Test func adyenReadsItsSnakeCaseKeys() throws {
        let config = try ApplePayRequestConfiguration.from(
            initResponse: initResponse(["country_code": "FR", "currency_code": "EUR"]),
            variant: .adyen,
            fallbackMerchantName: "Shop"
        )

        #expect(config.countryCode == "FR")
        #expect(config.currencyCode == "EUR")
        #expect(config.merchantName == "Shop")
    }

    /// The default variant nests its configuration inside a JSON *string*.
    @Test func theDefaultVariantUnwrapsItsNestedConfiguration() throws {
        let nested = #"{"configuration":{"merchantName":"Nested Shop"},"brands":["visa","masterCard"]}"#
        let config = try ApplePayRequestConfiguration.from(
            initResponse: initResponse([
                "country_code": "FR",
                "currency_code": "EUR",
                "payment_method_configuration": .string(nested),
            ]),
            variant: .default,
            fallbackMerchantName: "fallback"
        )

        #expect(config.merchantName == "Nested Shop")
        // These are Apple Pay JS network names ("visa", "masterCard"), not PKPaymentNetwork's own
        // raw values ("Visa", "MasterCard") — the mapper must translate, not cast.
        #expect(config.supportedNetworks == [.visa, .masterCard])
    }

    /// `PKPaymentNetwork(rawValue:)` on a JS name is not the mapper — it silently returns `nil` for
    /// every brand (`"visa"` ≠ `"Visa"`), which would make a real card's network vanish instead of
    /// resolving. Caught by comparing against the framework's actual raw values, not by pattern.
    @Test func jsNetworkNamesAreTranslatedNotCast() {
        #expect(ApplePayJSNetworkMapper.network(forJSName: "visa") == .visa)
        #expect(ApplePayJSNetworkMapper.network(forJSName: "masterCard") == .masterCard)
        #expect(ApplePayJSNetworkMapper.network(forJSName: "amex") == .amex)
        #expect(ApplePayJSNetworkMapper.network(forJSName: "cartesBancaires") == .cartesBancaires)
        // Proof the cast would have been wrong: PKPaymentNetwork's own raw value for amex is
        // "AmEx", not "Amex" — a plausible-looking guess that is still wrong.
        #expect(PKPaymentNetwork(rawValue: "amex") != .amex)
    }

    @Test func anUnknownJSNetworkNameIsDroppedNotGuessedAt() {
        #expect(ApplePayJSNetworkMapper.network(forJSName: "someFutureBrand") == nil)
    }

    @Test func missingNetworksFallBackToTheCatalogueDefault() throws {
        let config = try ApplePayRequestConfiguration.from(
            initResponse: initResponse(["country_code": "FR", "currency_code": "EUR"]),
            variant: .default,
            fallbackMerchantName: "Shop"
        )
        #expect(config.supportedNetworks == [.cartesBancaires, .masterCard, .visa])
    }

    /// PassKit rejects a request with no capabilities, so an unreadable list must not produce one.
    @Test(arguments: [nil, "", "[]", "not json"])
    func unreadableCapabilitiesFallBackTo3DS(_ raw: String?) throws {
        var logs: [String: JSONValue] = ["countryCode": "FR", "currencyCode": "EUR"]
        if let raw { logs["merchantCapabilities"] = .string(raw) }

        let config = try ApplePayRequestConfiguration.from(
            initResponse: initResponse(logs), variant: .ingenico, fallbackMerchantName: "Shop"
        )
        #expect(config.merchantCapabilities.contains(.threeDSecure))
    }

    /// An `/init` that carries no configuration is a failure, not an empty sheet.
    @Test func anInitWithoutLogsIsRefused() {
        #expect(throws: PartnerUIError.self) {
            try ApplePayRequestConfiguration.from(
                initResponse: .object(["status": .object(["state": "SUCCESS"])]),
                variant: .default,
                fallbackMerchantName: "Shop"
            )
        }
    }

    // MARK: Network vocabulary

    /// Apple's names are not the Payment API's — `AMEX` vs `AMERICAN_EXPRESS` again.
    @Test func networksMapToPaymentAPIVocabulary() {
        #expect(ApplePayNetworkMapper.selectedNetwork(for: .visa) == "VISA")
        #expect(ApplePayNetworkMapper.selectedNetwork(for: .amex) == "AMERICAN_EXPRESS")
        #expect(ApplePayNetworkMapper.selectedNetwork(for: .cartesBancaires) == "CARTE_BANCAIRE")
        #expect(ApplePayNetworkMapper.selectedNetwork(for: nil) == nil)
    }

    /// A network with no Payment API equivalent is dropped, not guessed at.
    @Test func unknownNetworksAreDropped() {
        #expect(ApplePayNetworkMapper.selectedNetwork(for: PKPaymentNetwork("someFutureNetwork")) == nil)
    }

    // MARK: The /validate payload

    private func context(collected: [String: JSONValue]) throws -> PartnerUIContext {
        let params = try SessionCodec.decode(TestSessions.widgetData())
        return PartnerUIContext(
            partner: .adyen,
            method: .applePay,
            session: params.paymentSession,
            amount: 100,
            api: PaymentAPIClient(
                apiKey: "k", apiRoot: "https://api.example/payment/v1",
                entityId: "e", sessionId: "s"
            ),
            collected: collected
        )
    }

    @Test func theAuthorizedTokenTravelsInPartnerData() async throws {
        let payload = try await ApplePayPlugin(partner: .adyen).preValidation(context(collected: [
            ApplePayPlugin.Collected.session: "{\"paymentMethod\":{}}",
            ApplePayPlugin.Collected.fingerprint: "txn-123",
            ApplePayPlugin.Collected.network: "VISA",
        ]))

        #expect(payload.partnerData["session"]?.stringValue == "{\"paymentMethod\":{}}")
        #expect(payload.paymentData["card"]?["fingerprint"]?.stringValue == "txn-123")
        #expect(payload.paymentData["card"]?["selected_network"]?.stringValue == "VISA")
        #expect(payload.partnerData["browser"] != nil)
        #expect(payload.method == .applePay)
    }

    /// Submitting without an authorized sheet would send an empty token.
    @Test func submittingWithoutAuthorizationIsRefused() async throws {
        let plugin = ApplePayPlugin(partner: .adyen)
        #expect(try await !plugin.validateUI(context(collected: [:])))

        await #expect(throws: PartnerUIError.self) {
            _ = try await plugin.preValidation(try context(collected: [:]))
        }
    }

    @Test func anAuthorizedSheetPassesValidateUI() async throws {
        let plugin = ApplePayPlugin(partner: .adyen)
        #expect(try await plugin.validateUI(context(collected: [
            ApplePayPlugin.Collected.session: "{}",
        ])))
    }

    // MARK: Registration

    /// Registered as a method fallback: the session decides which PSP handles Apple Pay.
    @Test func theModuleRegistersApplePayForAnyPartner() throws {
        let registry = PluginRegistry()
        registry.install(ApplePayModule())

        let protocols = ["adyen": ["applepay": ["configurations": ["stable": true, "labels": [], "settings": [:]]]]]
        let session = try SessionCodec.decode(
            TestSessions.widgetData(paymentSession: TestSessions.paymentSession(protocols: protocols))
        ).paymentSession

        let plugin = registry.plugin(partner: .adyen, method: .applePay, session: session)
        #expect(plugin is ApplePayPlugin)
    }

    @Test func installingTheModuleTwiceIsANoOp() {
        let registry = PluginRegistry()
        registry.install(ApplePayModule())
        registry.install(ApplePayModule())
        #expect(registry.modules.filter { $0 == "purse.applepay" }.count == 1)
    }

    // MARK: What the sheet must refuse to build

    /// A `PKPaymentRequest` with an empty country or currency cannot be presented, and PassKit does
    /// not say why — the sheet simply refuses, and `present()`'s diagnosis blames the entitlement.
    /// Defaulting those to `""` turned a server misconfiguration into a wild goose chase.
    @Test(arguments: ["country_code", "currency_code"])
    func refusesToBuildASheetWithoutACountryOrCurrency(_ missing: String) {
        var logs: [String: JSONValue] = ["country_code": "FR", "currency_code": "EUR"]
        logs.removeValue(forKey: missing)

        #expect(throws: PartnerUIError.self) {
            try ApplePayRequestConfiguration.from(
                initResponse: initResponse(logs),
                variant: .adyen,
                fallbackMerchantName: "Shop"
            )
        }
    }

    /// The fallback is the merchant's configured trading name. It used to be the payment session
    /// id, and with a single summary item PassKit renders that label as the grand-total line — so
    /// every Adyen sheet read `TOTAL <session-uuid>`.
    @Test func fallsBackToTheConfiguredMerchantNameNeverTheSessionId() throws {
        let config = try ApplePayRequestConfiguration.from(
            initResponse: initResponse(["country_code": "FR", "currency_code": "EUR"]),
            variant: .adyen,
            fallbackMerchantName: ApplePayConfiguration(
                merchantIdentifier: "merchant.com.example",
                merchantName: "Example Shop"
            ).merchantName
        )
        #expect(config.merchantName == "Example Shop")
    }

    /// A blank `merchantName` from `/init` is not a name — fall back rather than show the shopper
    /// an empty total line.
    @Test func treatsABlankMerchantNameFromInitAsAbsent() throws {
        let config = try ApplePayRequestConfiguration.from(
            initResponse: initResponse([
                "merchantName": "", "countryCode": "FR", "currencyCode": "EUR",
            ]),
            variant: .ingenico,
            fallbackMerchantName: "Example Shop"
        )
        #expect(config.merchantName == "Example Shop")
    }
}
