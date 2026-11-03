import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// The co-payment journey end to end: tokenize a gift card, draw it into the split, let a card
/// cover the rest, and check what actually reaches `/validate`.
@MainActor
@Suite(.serialized)
struct CoPaymentTests {

    /// Its own tier — the stub is keyed by host and suites run in parallel.
    private static let host = "api.purse-dev.com"

    private struct StubCardPlugin: PartnerUIPlugin {
        let partner: Partner
        let method: PaymentMethod
        func preValidation(_ context: PartnerUIContext) async throws -> ValidateItemPayload {
            ItemPayload(partner: partner, method: method, amount: context.amount)
        }
    }

    private struct StubModule: PartnerModule {
        let id = "test.copayment.card"
        @MainActor func register(into registry: PluginRegistry) {
            registry.registerVault(vendor: .purse) { StubCardPlugin(partner: $0.partner, method: $0.method) }
        }
    }

    /// A card method plus an Illicado gift card method.
    private static let protocols: [String: Any] = [
        "purse": ["creditcard": ["configurations": [
            "stable": true, "labels": [], "settings": [:],
            "vault": ["vendor": "purse", "supported_brands": ["VISA"]],
        ]]],
        "illicado": ["giftcard": ["configurations": [
            "stable": true, "labels": ["secondary"], "settings": [:],
        ]]],
    ]

    /// Its own **session id** as well as its own host.
    private func makeCheckout(protocols: [String: Any] = protocols) throws -> PurseHeadlessCheckout {
        let registry = PluginRegistry()
        registry.install(StubModule())
        return try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(
                environment: "development",
                paymentSession: TestSessions.paymentSession(
                    id: "co-payment-session",
                    amount: 100,
                    protocols: protocols
                )
            ),
            registry: registry,
            urlSession: StubURLProtocol.session()
        )
    }

    private func stub(initBody: String, validateBody: String = #"{"global_status":"SUCCESS","results":[]}"#) {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/init", .ok(initBody), host: Self.host)
        StubURLProtocol.set("/validate", .ok(validateBody), host: Self.host)
    }

    private static let giftCardInit = """
    {"status":{"state":"SUCCESS"},"plugin_result":{
      "payment_data":{"cards":[{"balance":30.00,"expiry_date":"2030-12-31"}]},
      "logs":{"masked_card":"•••• 7890"}}}
    """

    private let pan = "9250004781234567890"

    /// SDK-12563: the method's save policy reaches the token, so a `PREFER` gift card can be kept.
    @Test func aTokenizedGiftCardCarriesItsMethodsSavePolicy() async throws {
        stub(initBody: Self.giftCardInit)
        var protocols = Self.protocols
        protocols["illicado"] = ["giftcard": ["configurations": [
            "stable": true, "labels": ["secondary"], "settings": ["save_token_mode": "PREFER"],
        ]]]
        let checkout = try makeCheckout(protocols: protocols)

        let giftMethod = try #require(checkout.secondaryMethods.first)
        let token = try await checkout.getSecondaryToken(method: giftMethod, pan: pan, cvv: "123")

        #expect(token.saveTokenMode == .prefer)
        #expect(token.canBeRegistered)
        try checkout.registerSecondary(token)
    }

    @Test func aGiftCardOnANeverSaveMethodStaysUnregisterable() async throws {
        stub(initBody: Self.giftCardInit)
        let checkout = try makeCheckout()

        let giftMethod = try #require(checkout.secondaryMethods.first)
        let token = try await checkout.getSecondaryToken(method: giftMethod, pan: pan, cvv: "123")

        #expect(!token.canBeRegistered)
        #expect(throws: PurseCheckoutError.self) { try checkout.registerSecondary(token) }
    }

    @Test func aGiftCardAndACardSplitOneOrder() async throws {
        stub(initBody: Self.giftCardInit)
        let checkout = try makeCheckout()

        let giftMethod = try #require(checkout.secondaryMethods.first)
        let token = try await checkout.getSecondaryToken(method: giftMethod, pan: pan, cvv: "123")
        #expect(token.balance == Decimal(string: "30.00"))

        try checkout.applySecondary(token)
        #expect(checkout.remainingAmountToPay == 70)

        let card = checkout.paymentMethods.compactMap { item -> PrimaryMethod? in
            if case let .primaryMethod(method) = item { return method }
            return nil
        }.first
        try checkout.setPrimary(try #require(card))
        #expect(checkout.isPaymentFulfilled)

        _ = try await checkout.submitPayment()

        // Two items in one call: the gift card's slice, then the card's remainder.
        let items = try #require(StubURLProtocol.body(for: "/validate", host: Self.host)?.array)
        #expect(items.count == 2)
        #expect(items[0]["partner"]?.stringValue == "illicado")
        #expect(items[0]["amount"]?.decimalValue == 30)
        #expect(items[0]["payment_data"]?["card"]?["number"]?.stringValue == pan)
        #expect(items[0]["payment_data"]?["card"]?["csc"]?.stringValue == "123")
        #expect(items[1]["partner"]?.stringValue == "purse")
        #expect(items[1]["amount"]?.decimalValue == 70)
    }

    /// A gift card covering the whole order submits on its own, with no primary at all.
    @Test func aGiftCardCanCoverTheWholeOrderAlone() async throws {
        stub(initBody: """
        {"status":{"state":"SUCCESS"},"plugin_result":{
          "payment_data":{"cards":[{"balance":150.00}]},"logs":{}}}
        """)
        let checkout = try makeCheckout()

        let giftMethod = try #require(checkout.secondaryMethods.first)
        let token = try await checkout.getSecondaryToken(method: giftMethod, pan: pan, cvv: "123")
        try checkout.applySecondary(token)

        #expect(checkout.remainingAmountToPay == 0)
        #expect(checkout.isPaymentFulfilled)

        _ = try await checkout.submitPayment()
        let items = try #require(StubURLProtocol.body(for: "/validate", host: Self.host)?.array)
        #expect(items.count == 1)
        #expect(items[0]["amount"]?.decimalValue == 100)
    }

    /// Validation happens before the network — a malformed PAN never costs an `/init`.
    @Test func aMalformedPANIsRefusedWithoutCallingTheAPI() async throws {
        stub(initBody: Self.giftCardInit)
        let checkout = try makeCheckout()
        let giftMethod = try #require(checkout.secondaryMethods.first)

        await #expect(throws: PurseCheckoutError.self) {
            _ = try await checkout.getSecondaryToken(method: giftMethod, pan: "1234", cvv: "123")
        }
        #expect(!StubURLProtocol.paths(host: Self.host).contains { $0.hasSuffix("/init") })
    }

    @Test func aMissingSecurityCodeIsRefusedWithItsOwnCode() async throws {
        stub(initBody: Self.giftCardInit)
        let checkout = try makeCheckout()
        let giftMethod = try #require(checkout.secondaryMethods.first)

        do {
            _ = try await checkout.getSecondaryToken(method: giftMethod, pan: pan, cvv: nil)
            Issue.record("expected the missing CVV to be refused")
        } catch let error as PurseCheckoutError {
            #expect(error.code == .secondaryMethodRequiredCVV)
        }
    }

    /// An empty card reaches the API, and is refused with a distinguishable code.
    @Test func anEmptyGiftCardIsRefusedWithItsOwnCode() async throws {
        stub(initBody: """
        {"status":{"state":"SUCCESS"},"plugin_result":{
          "payment_data":{"cards":[{"balance":0}]},"logs":{}}}
        """)
        let checkout = try makeCheckout()
        let giftMethod = try #require(checkout.secondaryMethods.first)

        do {
            _ = try await checkout.getSecondaryToken(method: giftMethod, pan: pan, cvv: "123")
            Issue.record("expected the empty balance to be refused")
        } catch let error as PurseCheckoutError {
            #expect(error.code == .secondaryTokenEmptyBalance)
        }
    }

    /// Removing the gift card restores the full amount and un-fulfils the split.
    @Test func removingTheGiftCardRestoresTheAmount() async throws {
        stub(initBody: Self.giftCardInit)
        let checkout = try makeCheckout()

        let giftMethod = try #require(checkout.secondaryMethods.first)
        let token = try await checkout.getSecondaryToken(method: giftMethod, pan: pan, cvv: "123")
        try checkout.applySecondary(token)
        checkout.removeSecondary(token)

        #expect(checkout.remainingAmountToPay == 100)
        #expect(checkout.appliedSecondaries.isEmpty)
    }

    // MARK: What /init is actually asked for

    /// The `/init` must ask for the amount the instrument is being asked to cover, not 0.
    @Test func initRequestsTheAmountStillToCoverNotZero() async throws {
        stub(initBody: Self.giftCardInit)
        let checkout = try makeCheckout()
        let giftMethod = try #require(checkout.secondaryMethods.first)

        _ = try await checkout.getSecondaryToken(method: giftMethod, pan: pan, cvv: "123")

        let body = try #require(StubURLProtocol.body(for: "/init", host: Self.host)?.object)
        #expect(body["amount"]?.decimalValue == 100)
    }

    /// A terminal `/init` answer ends the whole session, not just this tokenization.
    @Test func aTerminalInitAnswerTerminatesTheSession() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/init", .failure(409, #"{"error":"SESSION_ALREADY_SUBMITTED_ERROR"}"#), host: Self.host)

        let checkout = try makeCheckout()
        let giftMethod = try #require(checkout.secondaryMethods.first)

        await #expect(throws: PurseCheckoutError.self) {
            _ = try await checkout.getSecondaryToken(method: giftMethod, pan: pan, cvv: "123")
        }
        #expect(checkout.sessionState == .terminated)
    }
}
