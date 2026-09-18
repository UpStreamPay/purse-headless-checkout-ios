import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// Save-at-submit: `PaymentValidator`'s `payment_preferences.registration` + `card.token_label`
/// enhancement, and `PurseHeadlessCheckout`'s `register(_:)`/`registrationOf(_:)` state.
@MainActor
@Suite(.serialized)
struct RegistrationTests {

    /// `PaymentAPIClient` takes any `apiRoot`, so this suite claims no `PurseEnvironment` tier.
    private static let host = "api.registrationtest.example"

    private struct StubCardPlugin: PartnerUIPlugin {
        let partner: Partner
        let method: PaymentMethod
        func preValidation(_ context: PartnerUIContext) async throws -> ValidateItemPayload {
            ItemPayload(partner: partner, method: method, amount: context.amount)
        }
    }

    private func validator() -> PaymentValidator {
        let registry = PluginRegistry()
        registry.registerVault(vendor: .purse) { StubCardPlugin(partner: $0.partner, method: $0.method) }
        return PaymentValidator(
            api: PaymentAPIClient(
                apiKey: "k", apiRoot: "https://\(Self.host)/payment/v1",
                entityId: "e", sessionId: "s", session: StubURLProtocol.session()
            ),
            registry: registry,
            configs: SecondaryConfigs()
        )
    }

    private func primaryMethodSplit(amount: Decimal = 100) throws -> (PaymentSplit, LegacyPaymentSession) {
        let params = try SessionCodec.decode(TestSessions.widgetData())
        let built = PaymentSessionBuilder.build(params.paymentSession, disabledMethods: [], configs: .shared)
        let method = try #require(built.meansOfPayment.compactMap { item -> PrimaryMethod? in
            if case let .primaryMethod(method) = item { return method }
            return nil
        }.first)
        return (PaymentSplit(amount: amount, source: method), params.paymentSession)
    }

    // MARK: PaymentValidator — the wire enhancement

    @Test func aPrimaryRegistrationAddsPreferencesAndLabel() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/validate", .ok(#"{"global_status":"SUCCESS","results":[]}"#), host: Self.host)

        let (split, session) = try primaryMethodSplit()
        _ = try await validator().execute(
            splits: [split], session: session,
            registrationByItem: [split.source.id: RegistrationState(registered: true, name: "My card")]
        )

        let items = try #require(StubURLProtocol.body(for: "/validate", host: Self.host)?.array)
        #expect(items.first?["payment_preferences"]?["registration"]?.boolValue == true)
        #expect(items.first?["payment_data"]?["card"]?["token_label"]?.stringValue == "My card")
    }

    /// An explicit `registered == false` still travels on the wire — only *no decision at all*
    /// (no map entry) leaves the payload untouched.
    @Test func anExplicitDeclineStillSendsTheFlag() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/validate", .ok(#"{"global_status":"SUCCESS","results":[]}"#), host: Self.host)

        let (split, session) = try primaryMethodSplit()
        _ = try await validator().execute(
            splits: [split], session: session,
            registrationByItem: [split.source.id: RegistrationState(registered: false)]
        )

        let items = try #require(StubURLProtocol.body(for: "/validate", host: Self.host)?.array)
        #expect(items.first?["payment_preferences"]?["registration"]?.boolValue == false)
        #expect(items.first?["payment_data"]?["card"] == nil)
    }

    @Test func noDecisionAtAllLeavesThePayloadUntouched() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/validate", .ok(#"{"global_status":"SUCCESS","results":[]}"#), host: Self.host)

        let (split, session) = try primaryMethodSplit()
        _ = try await validator().execute(splits: [split], session: session, registrationByItem: [:])

        let items = try #require(StubURLProtocol.body(for: "/validate", host: Self.host)?.array)
        #expect(items.first?["payment_preferences"]?["registration"] == nil)
    }

    /// A blank name never becomes a `token_label` — matches web's `!name.isNullOrBlank()` guard.
    @Test func aBlankNameNeverBecomesATokenLabel() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/validate", .ok(#"{"global_status":"SUCCESS","results":[]}"#), host: Self.host)

        let (split, session) = try primaryMethodSplit()
        _ = try await validator().execute(
            splits: [split], session: session,
            registrationByItem: [split.source.id: RegistrationState(registered: true, name: "  ")]
        )

        let items = try #require(StubURLProtocol.body(for: "/validate", host: Self.host)?.array)
        #expect(items.first?["payment_data"]?["card"] == nil)
    }

    /// A saved instrument is never re-registered, even with a decision in the map.
    @Test func aSavedSecondaryIsNeverReRegistered() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/validate", .ok(#"{"global_status":"SUCCESS","results":[]}"#), host: Self.host)

        let registry = PluginRegistry()
        let configs = SecondaryConfigs()
        let validator = PaymentValidator(
            api: PaymentAPIClient(
                apiKey: "k", apiRoot: "https://\(Self.host)/payment/v1",
                entityId: "e", sessionId: "s", session: StubURLProtocol.session()
            ),
            registry: registry,
            configs: configs
        )
        let params = try SessionCodec.decode(TestSessions.widgetData())
        let token = SecondaryToken(
            id: "illicado-giftcard-1", partner: .illicado, method: .giftCard,
            pan: "9250004781234567890", cvv: "123", name: "Saved card",
            balance: 10, isSaved: true
        )
        let split = PaymentSplit(amount: 10, source: token)

        _ = try await validator.execute(
            splits: [split], session: params.paymentSession,
            registrationByItem: [token.id: RegistrationState(registered: true, name: "Renamed")]
        )

        let items = try #require(StubURLProtocol.body(for: "/validate", host: Self.host)?.array)
        #expect(items.first?["payment_preferences"]?["registration"] == nil)
    }

    // MARK: PurseHeadlessCheckout — the decision state

    @Test func registrationOfDefaultsFromSaveTokenMode() throws {
        let protocols = TestSessions.cardProtocol(settings: ["save_token_mode": "ALWAYS"])
        let checkout = try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(paymentSession: TestSessions.paymentSession(protocols: protocols)),
            urlSession: StubURLProtocol.session()
        )
        let method = try #require(checkout.paymentMethods.compactMap { item -> PrimaryMethod? in
            if case let .primaryMethod(method) = item { return method }
            return nil
        }.first)
        #expect(checkout.registrationOf(method).registered)
    }

    @Test func registerRefusesAMethodThatCannotBeRegistered() throws {
        let protocols = TestSessions.cardProtocol(settings: ["save_token_mode": "NEVER"])
        let checkout = try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(paymentSession: TestSessions.paymentSession(protocols: protocols)),
            urlSession: StubURLProtocol.session()
        )
        let method = try #require(checkout.paymentMethods.compactMap { item -> PrimaryMethod? in
            if case let .primaryMethod(method) = item { return method }
            return nil
        }.first)
        do {
            try checkout.register(method)
            Issue.record("expected a non-registerable method to be refused")
        } catch let error as PurseCheckoutError {
            #expect(error.code == .methodNotRegisterable)
        }
    }

    @Test func registerRejectsAnInvalidLabel() throws {
        let protocols = TestSessions.cardProtocol(settings: ["save_token_mode": "PREFER"])
        let checkout = try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(paymentSession: TestSessions.paymentSession(protocols: protocols)),
            urlSession: StubURLProtocol.session()
        )
        let method = try #require(checkout.paymentMethods.compactMap { item -> PrimaryMethod? in
            if case let .primaryMethod(method) = item { return method }
            return nil
        }.first)
        do {
            try checkout.register(method, name: "bad!name")
            Issue.record("expected an invalid label to be refused")
        } catch let error as PurseCheckoutError {
            #expect(error.code == .invalidTokenName)
        }
    }

    // MARK: setSession

    /// A save-token decision belongs to the item that was on screen when the shopper made it.
    @Test func aRegistrationDecisionDoesNotSurviveAMethodItWasNotMadeFor() throws {
        let checkout = try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(
                paymentSession: TestSessions.paymentSession(
                    protocols: TestSessions.cardProtocol(settings: ["save_token_mode": "PREFER"])
                )
            ),
            urlSession: StubURLProtocol.session()
        )
        let method = try #require(checkout.paymentMethods.compactMap { item -> PrimaryMethod? in
            if case let .primaryMethod(method) = item { return method }
            return nil
        }.first)

        // Registered against the mode's default (PREFER is on), so a surviving decision and a
        // restored default cannot be confused.
        try checkout.register(method, registered: false, name: "Perso")
        #expect(!checkout.registrationOf(method).registered)
        #expect(checkout.registrationOf(method).name == "Perso")

        // A different `labels` set is a different configuration under the same id.
        try checkout.setSession(
            TestSessions.widgetData(
                paymentSession: TestSessions.paymentSession(
                    id: "session-2",
                    protocols: TestSessions.cardProtocol(
                        settings: ["save_token_mode": "PREFER"],
                        labels: ["different"]
                    )
                )
            )
        )

        let rebuilt = try #require(checkout.paymentMethods.compactMap { item -> PrimaryMethod? in
            if case let .primaryMethod(method) = item { return method }
            return nil
        }.first)
        #expect(rebuilt.id == method.id)
        // Back to the new method's own default, carrying none of the old decision.
        #expect(checkout.registrationOf(rebuilt).registered)
        #expect(checkout.registrationOf(rebuilt).name == nil)

        checkout.expiryWatchdog?.cancel()
    }
}
