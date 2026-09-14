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
    /// The host the sandbox session's API root resolves to — this suite's slice of the shared stub.
    private static let host = "api.purse-sandbox.com"

    /// A plugin whose `postValidation` throws — Klarna's does exactly this on a declined
    /// authorization, *after* `/validate` has already charged the payment.
    private struct ThrowingPostValidationPlugin: PartnerUIPlugin {
        let partner: Partner
        let method: PaymentMethod
        func preValidation(_ context: PartnerUIContext) async throws -> ValidateItemPayload {
            ItemPayload(partner: partner, method: method, amount: context.amount)
        }
        func postValidation(_ result: ValidationResult, context: PartnerUIContext) async throws {
            throw PartnerUIError("authorization declined")
        }
    }

    private func checkoutWhosePluginFailsAfterValidate() throws -> PurseHeadlessCheckout {
        let registry = PluginRegistry()
        registry.registerVault(vendor: .purse) {
            ThrowingPostValidationPlugin(partner: $0.partner, method: $0.method)
        }
        return try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(paymentSession: TestSessions.paymentSession(amount: 100)),
            registry: registry,
            urlSession: StubURLProtocol.session()
        )
    }

    /// Holds the checkout for a `@Sendable` hook to reach back into, and records what it saw.
    @MainActor private final class Interleave {
        var checkout: PurseHeadlessCheckout?
        var thrown: (any Error)?
        var didSucceed = false
    }

    // MARK: Happy path

    @Test func submitsOneValidateItemPerSplit() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/validate", .ok(Self.successBody), host: Self.host)

        let checkout = try makeCheckout()
        try selectCard(checkout)
        let result = try await checkout.submitPayment()

        #expect(result.isSuccess)
        #expect(checkout.sessionState == .submitted)

        let items = try #require(StubURLProtocol.body(for: "/validate", host: Self.host)?.array)
        #expect(items.count == 1)
        #expect(items[0]["partner"]?.stringValue == "purse")
        #expect(items[0]["amount"]?.decimalValue == 100)
        #expect(items[0]["payment_data"]?["vault_vendor"]?.stringValue == "purse")
    }

    // MARK: The latch

    /// A second submit is refused with a code, not silently ignored — Android's deliberate
    /// divergence from web, because a merchant needs something to react to (SDK-12218).
    @Test func aSecondSubmitIsRefusedWithACode() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/validate", .ok(Self.successBody), host: Self.host)

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
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/validate", .ok(#"{"global_status":"FAILED","results":[]}"#), host: Self.host)

        let checkout = try makeCheckout()
        try selectCard(checkout)
        let result = try await checkout.submitPayment()

        #expect(!result.isSuccess)
        await #expect(throws: PurseCheckoutError.self) { try await checkout.submitPayment() }
    }

    /// Expiry is re-evaluated before every submit, not only at initialisation.
    @Test func anExpiredSessionIsRefusedWithoutCallingThePSP() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/validate", .ok(Self.successBody), host: Self.host)

        let checkout = try makeCheckout(expirationDate: "2000-01-01T00:00:00Z")
        try selectCard(checkout)

        await #expect(throws: PurseCheckoutError.self) { try await checkout.submitPayment() }
        #expect(checkout.sessionState == .expired)
        #expect(!StubURLProtocol.paths(host: Self.host).contains { $0.hasSuffix("/validate") })
    }

    @Test func anUncoveredSplitIsRefusedWithoutCallingThePSP() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/validate", .ok(Self.successBody), host: Self.host)

        let checkout = try makeCheckout()
        // No primary selected, nothing applied.
        await #expect(throws: PurseCheckoutError.self) { try await checkout.submitPayment() }
        #expect(!StubURLProtocol.paths(host: Self.host).contains { $0.hasSuffix("/validate") })
        // Still submittable once a method is chosen.
        #expect(checkout.sessionState == .ready)
    }

    @Test func anIncompleteFormIsRefusedWithoutCallingThePSP() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/validate", .ok(Self.successBody), host: Self.host)

        let checkout = try makeCheckout()
        try selectCard(checkout)
        checkout.setFulfilled("purse-creditcard", false)

        await #expect(throws: PurseCheckoutError.self) { try await checkout.submitPayment() }
        #expect(!StubURLProtocol.paths(host: Self.host).contains { $0.hasSuffix("/validate") })
    }

    // MARK: Failures

    /// A 4xx leaves the checkout usable — the payment definitively did not happen.
    @Test func aRefusedValidateLeavesTheCheckoutSubmittable() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/validate", .failure(400, #"{"error":"INVALID_FORM"}"#), host: Self.host)

        let checkout = try makeCheckout()
        try selectCard(checkout)

        await #expect(throws: PurseCheckoutError.self) { try await checkout.submitPayment() }
        #expect(checkout.sessionState == .ready)
    }

    /// No answer came back: the payment may exist, so the session is spent rather than retried.
    /// Retrying here is what double-charges people.
    @Test func anUnknownOutcomeSpendsTheSessionRatherThanInvitingARetry() async throws {
        StubURLProtocol.reset(host: Self.host)
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
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/validate", .ok(Self.successBody), host: Self.host)

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
        #expect(!StubURLProtocol.paths(host: Self.host).contains { $0.hasSuffix("/validate") })
        #expect(checkout.sessionState == .ready)
    }

    /// onAfterValidate throwing is swallowed — the payment already happened.
    @Test func aFailingAfterHookDoesNotFailThePayment() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/validate", .ok(Self.successBody), host: Self.host)

        struct HookError: Error {}
        let hooks = PurseCheckoutHooks(onAfterValidate: { throw HookError() })
        let checkout = try makeCheckout(hooks: hooks)
        try selectCard(checkout)

        let result = try await checkout.submitPayment()
        #expect(result.isSuccess)
    }

    // MARK: Redirects

    @Test func surfacesAPendingRedirect() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set(
            "/validate",
            .ok(#"{"global_status":"WAITING","results":[],"redirection":{"url":"https://acs.bank.example/3ds"}}"#),
            host: Self.host
        )

        let checkout = try makeCheckout()
        try selectCard(checkout)
        let result = try await checkout.submitPayment()

        #expect(checkout.pendingRedirect(for: result) == .get(url: "https://acs.bank.example/3ds"))
    }

    @Test func noRedirectOnAPlainSuccess() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/validate", .ok(Self.successBody), host: Self.host)

        let checkout = try makeCheckout()
        try selectCard(checkout)
        let result = try await checkout.submitPayment()

        #expect(checkout.pendingRedirect(for: result) == nil)
    }

    // MARK: Missing plugin

    /// A method whose partner product was never installed names itself, rather than failing opaquely.
    @Test func aMissingPluginIsNamed() async throws {
        StubURLProtocol.reset(host: Self.host)
        // Strip the built-ins so the card method genuinely resolves to nothing — the shape a
        // merchant hits when a session offers PayPal but they never linked the PayPal product.
        let empty = PluginRegistry()
        empty.reset()
        let checkout = try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(
                paymentSession: TestSessions.paymentSession(amount: 100)
            ),
            registry: empty,
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

    // MARK: Session-spending correctness

    /// `/validate` answered — the payment exists — and a plugin then threw. The session is spent
    /// either way; treating this as "the submit failed" would let the next submit send a second
    /// `/validate` for an already-charged session.
    @Test func aPostValidationFailureStillSpendsTheSession() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.set("/validate", .ok(Self.successBody))

        let checkout = try checkoutWhosePluginFailsAfterValidate()
        try selectCard(checkout)

        do {
            _ = try await checkout.submitPayment()
            Issue.record("expected the postValidation failure to surface")
        } catch let error as PurseCheckoutError {
            #expect(error.code == .postValidateFailed)
            // The result rides along precisely because the payment is real.
            guard case let .postValidationFailed(result, _) = error else {
                Issue.record("expected postValidationFailed, got \(error)")
                return
            }
            #expect(result.isSuccess)
        }

        #expect(checkout.sessionState == .submitted)

        // The second submit must never reach the PSP.
        StubURLProtocol.reset()
        do {
            _ = try await checkout.submitPayment()
            Issue.record("expected the spent session to refuse a second submit")
        } catch let error as PurseCheckoutError {
            #expect(error.code == .submitBlocked)
        }
        #expect(!StubURLProtocol.paths.contains { $0.hasSuffix("/validate") })
    }

    /// A terminal API answer (already submitted / expired / gone) ends the session rather than
    /// leaving it looking submittable. The error arrives wrapped in `validateFailed`, so matching it
    /// means walking the chain, not casting the top-level error.
    @Test func aTerminalValidateAnswerTerminatesTheSession() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.set("/validate", .failure(409, #"{"error":"SESSION_ALREADY_SUBMITTED_ERROR"}"#))

        let checkout = try makeCheckout()
        try selectCard(checkout)

        await #expect(throws: PurseCheckoutError.self) {
            _ = try await checkout.submitPayment()
        }
        #expect(checkout.sessionState == .terminated)
    }

    /// `submitPayment` suspends at the `/validate` round trip, releasing the main actor.
    @Test func setSessionIsRefusedWhileASubmitIsInFlight() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.set("/validate", .ok(Self.successBody))

        let interleave = Interleave()
        let hooks = PurseCheckoutHooks(onBeforeValidate: { _ in
            await MainActor.run {
                do {
                    try interleave.checkout?.setSession(
                        TestSessions.widgetData(paymentSession: TestSessions.paymentSession(id: "session-2"))
                    )
                    interleave.didSucceed = true
                } catch {
                    interleave.thrown = error
                }
            }
        })

        let checkout = try makeCheckout(hooks: hooks)
        interleave.checkout = checkout
        try selectCard(checkout)
        _ = try await checkout.submitPayment()

        #expect(!interleave.didSucceed)
        #expect((interleave.thrown as? PurseCheckoutError)?.code == .submitBlocked)
        // The session that was actually submitted is still the one in force.
        #expect(checkout.currentSessionId == "session-1")
    }

    /// Expiry is checked against the **server** clock. `ServerDatetimeChecker` existed and was
    /// never consulted: nothing called `sync()` and nothing called `isExpiredForServer`, so a device
    /// clock running slow would submit an expired session.
    @Test func expiryIsCheckedAgainstTheServerClockNotTheDevices() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.set("/validate", .ok(Self.successBody))
        // The server is a year ahead of this device: a session that still has an hour left *by the
        // device clock* expired long ago as far as the server is concerned.
        let formatter = ISO8601DateFormatter()
        let serverNow = Date().addingTimeInterval(365 * 24 * 3600)
        StubURLProtocol.set("/datetime", .ok(#"{"iso":"\#(formatter.string(from: serverNow))"}"#))

        let checkout = try makeCheckout(
            expirationDate: formatter.string(from: Date().addingTimeInterval(3600))
        )
        await checkout.pendingClockSync?.value
        try selectCard(checkout)

        do {
            _ = try await checkout.submitPayment()
            Issue.record("expected the server clock to refuse an expired session")
        } catch let error as PurseCheckoutError {
            #expect(error.code == .expiredSession)
        }
        #expect(checkout.sessionState == .expired)
        checkout.expiryWatchdog?.cancel()
    }
}
