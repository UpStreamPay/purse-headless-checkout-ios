import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// The settled answer about a payment, read from the session's own transactions.
@MainActor
@Suite(.serialized)
struct PaymentSessionStatusTests {

    /// Its own host and session id: `StubURLProtocol`'s state is global and swift-testing runs
    /// suites in parallel, so sharing a host with `SubmitPaymentTests` had each suite's `reset`
    /// wiping the other's handlers.
    private static let host = "api.purse-confirmation.example"
    private static let sessionId = "confirmation-suite-session"

    private func makeCheckout() throws -> PurseHeadlessCheckout {
        try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(
                apiURL: "https://\(Self.host)/payment/v1",
                paymentSession: TestSessions.paymentSession(id: Self.sessionId, amount: 100)
            ),
            registry: PluginRegistry(),
            urlSession: StubURLProtocol.session()
        )
    }

    /// Only the transactions calls. Creating a checkout also reaches this host for the clock sync
    /// and monitoring, so a bare path count would never be 1.
    private static var transactionCalls: Int {
        StubURLProtocol.paths(host: host).filter { $0.hasSuffix("/sessions/\(sessionId)") }.count
    }

    private func stub(_ rows: String...) {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/sessions/\(Self.sessionId)", .ok("[\(rows.joined(separator: ","))]"), host: Self.host)
    }

    private func row(
        _ action: String, _ state: String, id: String = "t1", parent: String? = nil
    ) -> String {
        let parentField = parent.map { #""parent_transaction_id":"\#($0)","# } ?? ""
        return """
        {"id":"\(id)","partner":"purse","method":"creditcard",\(parentField)\
        "status":{"action":"\(action)","state":"\(state)","code":"OK"},\
        "plugin_result":{"partner_reference":"ref-\(id)"}}
        """
    }

    private func status() async throws -> PaymentSessionStatus {
        try await makeCheckout().paymentStatus()
    }

    // MARK: Classification

    @Test func aSuccessfulAuthorizeConfirms() async throws {
        stub(row("AUTHORIZE", "SUCCESS"))
        let status = try await status()
        #expect(status.verdict == "confirmed")
        #expect(status.operations.first?.partnerReference == "ref-t1")
    }

    /// Payment API v2 splits an auto-captured payment into `AUTHORIZE` plus `CAPTURE`, where v1
    /// sends one aggregate row. Both must read as one confirmed payment — which is why the
    /// classifier asks "any successful money operation?" rather than counting rows.
    @Test func aV2AuthorizeAndCapturePairIsOnePayment() async throws {
        stub(row("AUTHORIZE", "SUCCESS", id: "auth"), row("CAPTURE", "SUCCESS", id: "cap", parent: "auth"))
        let status = try await status()
        #expect(status.verdict == "confirmed")
        #expect(status.operations.count == 2)
        #expect(status.operations.last?.parentTransactionId == "auth")
    }

    @Test func moneyOperationsAllFailedMeanFailed() async throws {
        stub(row("AUTHORIZE", "ERROR", id: "a"), row("CAPTURE", "FAILED", id: "b"))
        #expect(try await status().verdict == "failed")
    }

    /// One failure among successes is not a failed payment — a retried authorization is the
    /// ordinary way to see both.
    @Test func oneSuccessAmongFailuresStillConfirms() async throws {
        stub(row("AUTHORIZE", "ERROR", id: "a"), row("AUTHORIZE", "SUCCESS", id: "b"))
        #expect(try await status().verdict == "confirmed")
    }

    /// `WAITING` and `UNCERTAIN` have not settled; reading either as failed would tell a shopper
    /// their paid order did not go through. An init-only session is pending for the same reason:
    /// a method that would not start has not spent the session.
    @Test func unsettledAndInitOnlySessionsArePending() async throws {
        stub(row("INIT", "SUCCESS"))
        #expect(try await status().verdict == "pending")

        stub(row("AUTHORIZE", "WAITING", id: "a"), row("CAPTURE", "UNCERTAIN", id: "b"))
        #expect(try await status().verdict == "pending")

        stub()
        #expect(try await status() == .pending([]))
    }

    // MARK: Parsing

    /// A row the SDK cannot read must not cost the caller the answer about the rows it can.
    @Test func aRowWithoutAStatusIsSkippedNotFatal() async throws {
        stub(#"{"id":"junk","partner":"purse"}"#, row("AUTHORIZE", "SUCCESS"))
        let status = try await status()
        #expect(status.verdict == "confirmed")
        #expect(status.operations.count == 1)
    }

    @Test func blankWireFieldsReadAsAbsent() async throws {
        stub("""
        {"id":"","partner":"purse","method":"creditcard",\
        "status":{"action":"AUTHORIZE","state":"SUCCESS","code":""}}
        """)
        let operation = try #require(try await status().operations.first)
        #expect(operation.id == nil)
        #expect(operation.code == nil)
        #expect(operation.parentTransactionId == nil)
        #expect(operation.partnerReference == nil)
    }

    @Test func sessionTransactionsReturnsTheRawRows() async throws {
        stub(row("AUTHORIZE", "SUCCESS"))
        let rows = try await makeCheckout().sessionTransactions()
        #expect(rows.first?["status"]?["action"]?.stringValue == "AUTHORIZE")
    }

    // MARK: Polling

    @Test func awaitReturnsImmediatelyOnASettledStatus() async throws {
        stub(row("AUTHORIZE", "SUCCESS"))
        let status = try await makeCheckout().awaitPaymentOutcome(
            timeout: .seconds(5), pollInterval: .milliseconds(10)
        )
        #expect(status.verdict == "confirmed")
        // Asked once, not polled: a settled answer needs no second call.
        #expect(Self.transactionCalls == 1)
    }

    /// The honest answer at timeout is the last pending status, not a throw — a caller that has
    /// just taken money needs something to show the shopper.
    @Test func awaitReturnsThePendingStatusAtTimeout() async throws {
        stub(row("AUTHORIZE", "WAITING"))
        let status = try await makeCheckout().awaitPaymentOutcome(
            timeout: .milliseconds(30), pollInterval: .milliseconds(10)
        )
        #expect(status.verdict == "pending")
        #expect(Self.transactionCalls > 1)
    }

    /// Same contract when the caller's screen goes away mid-poll: `Task.sleep` throws on
    /// cancellation, and that must not reach a caller promised a status.
    @Test func awaitReturnsTheLastStatusWhenCancelledMidPoll() async throws {
        stub(row("AUTHORIZE", "WAITING"))
        let checkout = try makeCheckout()
        let task = Task {
            try await checkout.awaitPaymentOutcome(timeout: .seconds(10), pollInterval: .seconds(1))
        }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        #expect(try await task.value.verdict == "pending")
    }

    // MARK: Teardown

    @Test func everyConfirmationCallIsRefusedAfterTeardown() async throws {
        stub(row("AUTHORIZE", "SUCCESS"))
        let checkout = try makeCheckout()
        checkout.teardown()

        await #expect(throws: PurseCheckoutError.self) { try await checkout.sessionTransactions() }
        await #expect(throws: PurseCheckoutError.self) { try await checkout.paymentStatus() }
        await #expect(throws: PurseCheckoutError.self) {
            try await checkout.awaitPaymentOutcome(timeout: .milliseconds(10), pollInterval: .milliseconds(5))
        }
    }
}

private extension PaymentSessionStatus {
    /// Names the case, so an assertion is one line instead of a `guard case` block.
    var verdict: String {
        switch self {
        case .confirmed: "confirmed"
        case .failed: "failed"
        case .pending: "pending"
        }
    }
}
