import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// The create-payment pipeline and the latch that guards it. Serialized because `StubURLProtocol`
/// keys its handlers globally, so parallel cases would hand each other the wrong response.
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
        expirationDate: String = "2099-01-01T00:00:00Z",
        serverClock: ServerDatetimeChecker? = nil
    ) throws -> PurseHeadlessCheckout {
        let registry = PluginRegistry()
        registry.install(StubModule())
        return try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(
                paymentSession: TestSessions.paymentSession(amount: 100, expirationDate: expirationDate)
            ),
            hooks: hooks,
            registry: registry,
            urlSession: StubURLProtocol.session(),
            serverClockOverride: serverClock
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

    /// Throws in `postValidation`, as Klarna's does on a declined authorization — *after*
    /// `/validate` has already charged the payment.
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

    /// Deliberate divergence from web: a merchant needs a code to react to.
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

    /// Two taps in the same turn: sequential calls serialize and pass even against a broken latch.
    /// The clock sleeps 50 ms to widen the actor hop, so the second tap lands inside the window.
    @Test func twoConcurrentSubmitsSendOneValidate() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/validate", .ok(Self.successBody), host: Self.host)

        let slowClock = ServerDatetimeChecker(
            fetchServerTime: { Date() },
            clock: { Thread.sleep(forTimeInterval: 0.05); return Date() }
        )
        let checkout = try makeCheckout(serverClock: slowClock)
        try selectCard(checkout)

        let first = Task { try await checkout.submitPayment() }
        let second = Task { try await checkout.submitPayment() }
        let outcomes = await [first.result, second.result]

        #expect(StubURLProtocol.paths(host: Self.host).filter { $0.hasSuffix("/validate") }.count == 1)
        #expect(outcomes.filter { (try? $0.get()) != nil }.count == 1)
        let refusal = outcomes.compactMap { result -> PurseCheckoutError? in
            if case let .failure(error) = result { return error as? PurseCheckoutError }
            return nil
        }.first
        #expect(refusal?.code == .submitBlocked)
        // `.submitting`, not `.submitted`: a pair that never overlapped produces the same counts and
        // the same code, so only the state proves the two taps really raced.
        guard case let .submitBlocked(state) = refusal else {
            Issue.record("expected submitBlocked, got \(String(describing: refusal))")
            return
        }
        #expect(state == .submitting)
    }

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
        // No handler for /validate: the stub fails with a transport error, the "no HTTP status" shape.
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
        // Built-ins stripped so the method resolves to nothing, as when a merchant never links the
        // partner product a session offers.
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

    /// `/validate` answered, then a plugin threw. Treating that as "the submit failed" would send a
    /// second `/validate` for an already-charged session.
    @Test func aPostValidationFailureStillSpendsTheSession() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/validate", .ok(Self.successBody), host: Self.host)

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
        StubURLProtocol.reset(host: Self.host)
        do {
            _ = try await checkout.submitPayment()
            Issue.record("expected the spent session to refuse a second submit")
        } catch let error as PurseCheckoutError {
            #expect(error.code == .submitBlocked)
        }
        #expect(!StubURLProtocol.paths(host: Self.host).contains { $0.hasSuffix("/validate") })
    }

    /// A terminal API answer (already submitted / expired / gone) ends the session rather than
    /// leaving it looking submittable.
    @Test func aTerminalValidateAnswerTerminatesTheSession() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/validate", .failure(409, #"{"error":"SESSION_ALREADY_SUBMITTED_ERROR"}"#), host: Self.host)

        let checkout = try makeCheckout()
        try selectCard(checkout)

        await #expect(throws: PurseCheckoutError.self) {
            _ = try await checkout.submitPayment()
        }
        #expect(checkout.sessionState == .terminated)
    }

    /// `submitPayment` suspends at the `/validate` round trip, releasing the main actor.
    @Test func setSessionIsRefusedWhileASubmitIsInFlight() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/validate", .ok(Self.successBody), host: Self.host)

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

    /// A device clock running slow must not be able to submit an expired session.
    @Test func expiryIsCheckedAgainstTheServerClockNotTheDevices() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/validate", .ok(Self.successBody), host: Self.host)
        // Server a year ahead: an hour of life by the device clock, long expired by the server's.
        let formatter = ISO8601DateFormatter()
        let serverNow = Date().addingTimeInterval(365 * 24 * 3600)
        StubURLProtocol.set("/datetime", .ok(#"{"iso":"\#(formatter.string(from: serverNow))"}"#), host: Self.host)

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

/// The redirect hand-off: what the checkout does with a `/validate` that asks for one.
@MainActor
@Suite(.serialized)
struct RedirectHandoffTests {

    /// A different tier from SubmitPaymentTests on purpose: the stub is keyed by host and the two
    /// suites run in parallel.
    private static let host = "api.purse-test.com"

    private struct StubCardPlugin: PartnerUIPlugin {
        let partner: Partner
        let method: PaymentMethod
        func preValidation(_ context: PartnerUIContext) async throws -> ValidateItemPayload {
            ItemPayload(partner: partner, method: method, amount: context.amount)
        }
    }

    private struct StubModule: PartnerModule {
        let id = "test.redirect.card"
        @MainActor func register(into registry: PluginRegistry) {
            registry.registerVault(vendor: .purse) { StubCardPlugin(partner: $0.partner, method: $0.method) }
        }
    }

    /// Records what it was asked to present, and answers with whatever the test wants.
    private final class SpyPresenter: RedirectPresenter {
        var presented: [RedirectAction] = []
        var answer: RedirectOutcome = .returned(url: nil)

        func present(_ action: RedirectAction) async throws -> RedirectOutcome {
            presented.append(action)
            return answer
        }
    }

    private func checkout(hooks: PurseCheckoutHooks? = nil) throws -> PurseHeadlessCheckout {
        let registry = PluginRegistry()
        registry.install(StubModule())
        let checkout = try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(
                environment: "test",
                paymentSession: TestSessions.paymentSession(amount: 100)
            ),
            hooks: hooks,
            registry: registry,
            urlSession: StubURLProtocol.session()
        )
        let method = checkout.paymentMethods.compactMap { item -> PrimaryMethod? in
            if case let .primaryMethod(method) = item { return method }
            return nil
        }.first!
        try checkout.setPrimary(method)
        return checkout
    }

    private func stubValidate(_ body: String) {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/validate", .ok(body), host: Self.host)
    }

    private static let withRedirect =
        #"{"global_status":"WAITING","results":[],"redirection":{"url":"https://acs.bank.example/3ds"}}"#

    @Test func presentsTheRedirectAValidateAsksFor() async throws {
        stubValidate(Self.withRedirect)
        let checkout = try checkout()
        let presenter = SpyPresenter()

        let result = try await checkout.submitPayment()
        let outcome = try await checkout.presentRedirectIfNeeded(for: result, using: presenter)

        #expect(outcome == .returned(url: nil))
        #expect(presenter.presented == [.get(url: "https://acs.bank.example/3ds")])
    }

    @Test func presentsNothingWhenNoRedirectIsAskedFor() async throws {
        stubValidate(#"{"global_status":"SUCCESS","results":[]}"#)
        let checkout = try checkout()
        let presenter = SpyPresenter()

        let result = try await checkout.submitPayment()
        let outcome = try await checkout.presentRedirectIfNeeded(for: result, using: presenter)

        #expect(outcome == nil)
        #expect(presenter.presented.isEmpty)
    }

    /// A merchant returning `true` takes the redirect over: the SDK opens nothing.
    @Test func theMerchantHookCanTakeTheRedirectOver() async throws {
        stubValidate(Self.withRedirect)
        let hooks = PurseCheckoutHooks(onRedirection: { _ in true })
        let checkout = try checkout(hooks: hooks)
        let presenter = SpyPresenter()

        let result = try await checkout.submitPayment()
        let outcome = try await checkout.presentRedirectIfNeeded(for: result, using: presenter)

        #expect(outcome == nil)
        #expect(presenter.presented.isEmpty)
    }

    @Test func theMerchantHookCanDeclineToTakeItOver() async throws {
        stubValidate(Self.withRedirect)
        let hooks = PurseCheckoutHooks(onRedirection: { _ in false })
        let checkout = try checkout(hooks: hooks)
        let presenter = SpyPresenter()

        let result = try await checkout.submitPayment()
        _ = try await checkout.presentRedirectIfNeeded(for: result, using: presenter)

        #expect(presenter.presented.count == 1)
    }

    /// A throwing hook opens nothing, and reports as a post-validate failure.
    @Test func aThrowingHookOpensNothing() async throws {
        struct HookError: Error {}
        stubValidate(Self.withRedirect)
        let hooks = PurseCheckoutHooks(onRedirection: { _ in throw HookError() })
        let checkout = try checkout(hooks: hooks)
        let presenter = SpyPresenter()

        let result = try await checkout.submitPayment()
        do {
            _ = try await checkout.presentRedirectIfNeeded(for: result, using: presenter)
            Issue.record("expected the hook failure to surface")
        } catch let error as PurseCheckoutError {
            #expect(error.code == .postValidateFailed)
        }
        #expect(presenter.presented.isEmpty)
    }

    /// A cancelled redirect is reported as such — the shopper may try again.
    @Test func aCancelledRedirectIsReportedAsCancelled() async throws {
        stubValidate(Self.withRedirect)
        let checkout = try checkout()
        let presenter = SpyPresenter()
        presenter.answer = .canceled

        let result = try await checkout.submitPayment()
        #expect(try await checkout.presentRedirectIfNeeded(for: result, using: presenter) == .canceled)
    }

    /// The widget's own confirmation hop is not a redirect worth presenting.
    @Test func theWidgetConfirmationHopIsNotPresented() async throws {
        stubValidate(
            #"{"global_status":"SUCCESS","results":[],"redirection":{"url":"https://shop.example/c?purse-redirection-data=x"}}"#
        )
        let checkout = try checkout()
        let presenter = SpyPresenter()

        let result = try await checkout.submitPayment()
        #expect(try await checkout.presentRedirectIfNeeded(for: result, using: presenter) == nil)
        #expect(presenter.presented.isEmpty)
    }
}
