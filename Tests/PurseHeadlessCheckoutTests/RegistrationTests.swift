import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// Save-at-submit: `PaymentValidator`'s `payment_preferences.registration` + `card.token_label`
/// enhancement, and `PurseHeadlessCheckout`'s `register(_:)`/`registrationOf(_:)` state.
@MainActor
@Suite(.serialized)
struct RegistrationTests {

    /// `PaymentAPIClient` takes any `apiRoot` directly, so this suite claims no `PurseEnvironment`
    /// tier at all — same technique as `LoanSimulationTests`.
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

    /// A saved instrument (already registered) is never re-registered, even if a decision exists in
    /// the map — Android's `!source.isSaved` guard for secondaries; the primary path enforces the
    /// same by construction (a `PaymentToken` never appears in `registrationByItem`).
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
}
