import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// `teardown()` / `isTornDown` — releasing resources and refusing further use. None of these tests
/// touch the network (a non-simulable gate, or `requireOpen()` itself, refuses before any call is
/// made), so this suite claims no `PurseEnvironment` tier.
@MainActor
struct TeardownTests {

    private func checkout(simulable: Bool = false) throws -> PurseHeadlessCheckout {
        let protocols = TestSessions.cardProtocol(labels: simulable ? ["simulable"] : [])
        return try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(paymentSession: TestSessions.paymentSession(protocols: protocols)),
            urlSession: StubURLProtocol.session()
        )
    }

    @Test func teardownSetsIsTornDown() throws {
        let checkout = try checkout()
        #expect(!checkout.isTornDown)
        checkout.teardown()
        #expect(checkout.isTornDown)
    }

    @Test func teardownIsIdempotent() throws {
        let checkout = try checkout()
        checkout.teardown()
        checkout.teardown()
        #expect(checkout.isTornDown)
    }

    @Test func submitPaymentRefusesAfterTeardown() async throws {
        let checkout = try checkout()
        checkout.teardown()
        do {
            _ = try await checkout.submitPayment()
            Issue.record("expected submitPayment to be refused after teardown")
        } catch let error as PurseCheckoutError {
            #expect(error.code == .checkoutTornDown)
        }
    }

    @Test func setSessionRefusesAfterTeardown() throws {
        let checkout = try checkout()
        checkout.teardown()
        do {
            try checkout.setSession(TestSessions.widgetData(paymentSession: TestSessions.paymentSession(id: "session-2")))
            Issue.record("expected setSession to be refused after teardown")
        } catch let error as PurseCheckoutError {
            #expect(error.code == .checkoutTornDown)
        }
    }

    @Test func saveStateRefusesAfterTeardown() throws {
        let checkout = try checkout()
        checkout.teardown()
        do {
            _ = try checkout.saveState()
            Issue.record("expected saveState to be refused after teardown")
        } catch let error as PurseCheckoutError {
            #expect(error.code == .checkoutTornDown)
        }
    }

    @Test func loanSimulationRefusesAfterTeardown() async throws {
        let checkout = try checkout(simulable: true)
        let method = try #require(checkout.paymentMethods.compactMap { item -> PrimaryMethod? in
            if case let .primaryMethod(method) = item { return method }
            return nil
        }.first)
        checkout.teardown()
        do {
            _ = try await checkout.simulateLoan(method, product: LoanProduct(amount: 10, currencyCode: "EUR"))
            Issue.record("expected simulateLoan to be refused after teardown")
        } catch let error as PurseCheckoutError {
            #expect(error.code == .checkoutTornDown)
        }
    }

    /// Any in-flight background work started at construction is cancelled, not left to run against
    /// a checkout nothing can observe any more.
    @Test func teardownCancelsPendingBackgroundWork() throws {
        let token: [String: Any] = ["id": "tok-1", "value": "v1", "uniqueness_token": "9250004781234567890", "pin_code": "123"]
        let protocols = ["illicado": ["giftcard": [
            "configurations": ["stable": true, "labels": ["secondary"], "settings": [:]],
            "integrated_tokens": [token]
        ]]]
        let checkout = try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(paymentSession: TestSessions.paymentSession(protocols: protocols)),
            urlSession: StubURLProtocol.session()
        )
        let pending = try #require(checkout.pendingSecondaryBalanceResolution)
        checkout.teardown()
        #expect(pending.isCancelled)
    }
}
