import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// The create-payment pipeline and the latch that guards it. Serialized: `StubURLProtocol` keys its
/// handlers globally, and swift-testing runs tests in parallel by default, so unserialized cases
/// here would hand each other the wrong response.
@MainActor
@Suite(.serialized)
struct SubmitPaymentTests {

    /// A minimal plugin so a card method resolves without Secure Fields.
    private struct StubCardPlugin: PartnerUIPlugin {
        let partner: Partner
        let method: PaymentMethod
        func preValidation(_ context: PartnerUIContext) async throws -> ValidateItemPayload {
            ItemPayload(
                partner: partner,
                method: method,
                amount: context.amount,
                paymentData: ["vault_vendor": "purse"]
            )
        }
    }

    private struct StubModule: PartnerModule {
        let id = "test.card"
        @MainActor func register(into registry: PluginRegistry) {
            registry.registerVault(vendor: .purse) { StubCardPlugin(partner: $0.partner, method: $0.method) }
        }
    }

    private func makeCheckout(
        hooks: PurseCheckoutHooks? = nil,
        expirationDate: String = "2099-01-01T00:00:00Z"
    ) throws -> PurseHeadlessCheckout {
        let registry = PluginRegistry()
        registry.install(StubModule())
        return try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(
                paymentSession: TestSessions.paymentSession(amount: 100, expirationDate: expirationDate)
            ),
            hooks: hooks,
            registry: registry,
            urlSession: StubURLProtocol.session()
        )
    }

    private func selectCard(_ checkout: PurseHeadlessCheckout) throws {
        let method = checkout.paymentMethods.compactMap { item -> PrimaryMethod? in
            if case let .primaryMethod(method) = item { return method }
            return nil
        }.first
        try checkout.setPrimary(try #require(method))
    }

    private static let successBody = #"{"global_status":"SUCCESS","results":[]}"#

    // MARK: Happy path

    @Test func submitsOneValidateItemPerSplit() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.set("/validate", .ok(Self.successBody))

        let checkout = try makeCheckout()
        try selectCard(checkout)
        let result = try await checkout.submitPayment()

        #expect(result.isSuccess)
        #expect(checkout.sessionState == .submitted)

        let items = try #require(StubURLProtocol.body(for: "/validate")?.array)
        #expect(items.count == 1)
        #expect(items[0]["partner"]?.stringValue == "purse")
        #expect(items[0]["amount"]?.decimalValue == 100)
        #expect(items[0]["payment_data"]?["vault_vendor"]?.stringValue == "purse")
    }

    // MARK: The latch

    /// A second submit is refused with a code, not silently ignored — Android's deliberate
    /// divergence from web, because a merchant needs something to react to (SDK-12218).
    @Test func aSecondSubmitIsRefusedWithACode() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.set("/validate", .ok(Self.successBody))

        let checkout = try makeCheckout()
        try selectCard(checkout)
        _ = try await checkout.submitPayment()

        await #expect(throws: PurseCheckoutError.self) { try await checkout.submitPayment() }
        do {
            _ = try await checkout.submitPayment()
        } catch let error as PurseCheckoutError {
            #expect(error.code == .submitBlocked)
        }
    }

    /// A declined payment spends the session exactly as a successful one does.
    @Test func aDeclinedPaymentStillSpendsTheSession() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.set("/validate", .ok(#"{"global_status":"FAILED","results":[]}"#))

        let checkout = try makeCheckout()
        try selectCard(checkout)
        let result = try await checkout.submitPayment()

        #expect(!result.isSuccess)
        await #expect(throws: PurseCheckoutError.self) { try await checkout.submitPayment() }
    }

    /// Expiry is re-evaluated before every submit, not only at initialisation.
    @Test func anExpiredSessionIsRefusedWithoutCallingThePSP() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.set("/validate", .ok(Self.successBody))

        let checkout = try makeCheckout(expirationDate: "2000-01-01T00:00:00Z")
        try selectCard(checkout)

        await #expect(throws: PurseCheckoutError.self) { try await checkout.submitPayment() }
        #expect(checkout.sessionState == .expired)
        #expect(!StubURLProtocol.paths.contains { $0.hasSuffix("/validate") })
    }

    @Test func anUncoveredSplitIsRefusedWithoutCallingThePSP() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.set("/validate", .ok(Self.successBody))

        let checkout = try makeCheckout()
        // No primary selected, nothing applied.
        await #expect(throws: PurseCheckoutError.self) { try await checkout.submitPayment() }
        #expect(!StubURLProtocol.paths.contains { $0.hasSuffix("/validate") })
        // Still submittable once a method is chosen.
        #expect(checkout.sessionState == .ready)
    }

    @Test func anIncompleteFormIsRefusedWithoutCallingThePSP() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.set("/validate", .ok(Self.successBody))

        let checkout = try makeCheckout()
        try selectCard(checkout)
        checkout.setFulfilled("purse-creditcard", false)

        await #expect(throws: PurseCheckoutError.self) { try await checkout.submitPayment() }
        #expect(!StubURLProtocol.paths.contains { $0.hasSuffix("/validate") })
    }

    // MARK: Failures

    /// A 4xx leaves the checkout usable — the payment definitively did not happen.
    @Test func aRefusedValidateLeavesTheCheckoutSubmittable() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.set("/validate", .failure(400, #"{"error":"INVALID_FORM"}"#))

        let checkout = try makeCheckout()
        try selectCard(checkout)

        await #expect(throws: PurseCheckoutError.self) { try await checkout.submitPayment() }
        #expect(checkout.sessionState == .ready)
    }

    /// No answer came back: the payment may exist, so the session is spent rather than retried.
    /// Retrying here is what double-charges people.
    @Test func anUnknownOutcomeSpendsTheSessionRatherThanInvitingARetry() async throws {
        StubURLProtocol.reset()
        // No handler registered for /validate → the stub fails the request with a transport error,
        // which is exactly the "no HTTP status came back" shape.
        let checkout = try makeCheckout()
        try selectCard(checkout)

        do {
            _ = try await checkout.submitPayment()
            Issue.record("expected the submit to throw")
        } catch let error as PurseCheckoutError {
            let apiError = error.underlying as? PaymentAPIError
            #expect(apiError?.outcomeUnknown == true)
        }
        #expect(checkout.sessionState == .submitted)
        await #expect(throws: PurseCheckoutError.self) { try await checkout.submitPayment() }
    }

    // MARK: Hooks

    /// onBeforeValidate throwing aborts before anything is sent, and leaves the checkout usable.
    @Test func aFailingBeforeHookAbortsBeforeAnythingIsSent() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.set("/validate", .ok(Self.successBody))

        struct HookError: Error {}
        let hooks = PurseCheckoutHooks(onBeforeValidate: { _ in throw HookError() })
        let checkout = try makeCheckout(hooks: hooks)
        try selectCard(checkout)

        do {
            _ = try await checkout.submitPayment()
            Issue.record("expected the hook failure to abort the submit")
        } catch let error as PurseCheckoutError {
            #expect(error.code == .onBeforeValidateHookFailed)
        }
        #expect(!StubURLProtocol.paths.contains { $0.hasSuffix("/validate") })
        #expect(checkout.sessionState == .ready)
    }

    /// onAfterValidate throwing is swallowed — the payment already happened.
    @Test func aFailingAfterHookDoesNotFailThePayment() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.set("/validate", .ok(Self.successBody))

        struct HookError: Error {}
        let hooks = PurseCheckoutHooks(onAfterValidate: { throw HookError() })
        let checkout = try makeCheckout(hooks: hooks)
        try selectCard(checkout)

        let result = try await checkout.submitPayment()
        #expect(result.isSuccess)
    }

    // MARK: Redirects

    @Test func surfacesAPendingRedirect() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.set("/validate", .ok(
            #"{"global_status":"WAITING","results":[],"redirection":{"url":"https://acs.bank.example/3ds"}}"#
        ))

        let checkout = try makeCheckout()
        try selectCard(checkout)
        let result = try await checkout.submitPayment()

        #expect(checkout.pendingRedirect(for: result) == .get(url: "https://acs.bank.example/3ds"))
    }

    @Test func noRedirectOnAPlainSuccess() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.set("/validate", .ok(Self.successBody))

        let checkout = try makeCheckout()
        try selectCard(checkout)
        let result = try await checkout.submitPayment()

        #expect(checkout.pendingRedirect(for: result) == nil)
    }

    // MARK: Missing plugin

    /// A method whose partner product was never installed names itself, rather than failing opaquely.
    @Test func aMissingPluginIsNamed() async throws {
        StubURLProtocol.reset()
        let checkout = try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(
                paymentSession: TestSessions.paymentSession(amount: 100)
            ),
            registry: PluginRegistry(),
            urlSession: StubURLProtocol.session()
        )
        try selectCard(checkout)

        do {
            _ = try await checkout.submitPayment()
            Issue.record("expected a missing-plugin failure")
        } catch let error as PurseCheckoutError {
            #expect(error.code == .methodNotImplemented)
            #expect(error.message.contains("purse-creditcard"))
        }
    }
}
