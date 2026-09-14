import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// Background `/init` resolution for saved gift cards — sequential, per Android's
/// `InitGuard`-coalescing lesson (`AGENTS.md`).
@MainActor
@Suite(.serialized)
struct SavedSecondaryBalanceTests {

    private static let host = "api.purse-live.com"

    /// Illicado's own PAN shape: a 9-digit prefix + 10 digits.
    private static let illicadoPAN = "9250004781234567890"

    /// Its own **session id**, not just its own host.
    private func widgetData(protocols: [String: Any], amount: Any = 100) -> String {
        TestSessions.widgetData(
            environment: "production",
            paymentSession: TestSessions.paymentSession(
                id: "saved-secondary-session",
                amount: amount,
                protocols: protocols
            )
        )
    }

    /// A saved illicado gift card under a secondary method — a config `SecondaryConfigs` ships
    /// built in for, unlike `purse-creditcard`.
    private func illicadoProtocols(pan: String = illicadoPAN, cvv: String? = "123") -> [String: Any] {
        var token: [String: Any] = ["id": "tok-1", "value": "v1", "uniqueness_token": pan]
        if let cvv { token["pin_code"] = cvv }
        return [
            "illicado": [
                "giftcard": [
                    "configurations": ["stable": true, "labels": ["secondary"], "settings": [:]],
                    "integrated_tokens": [token]
                ]
            ]
        ]
    }

    private func makeCheckout(widgetData: String) throws -> PurseHeadlessCheckout {
        try PurseHeadlessCheckout(widgetData: widgetData, urlSession: StubURLProtocol.session())
    }

    // MARK: Success

    @Test func resolvesBalanceForARegisteredIssuer() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set(
            "/init",
            .ok(#"""
            {"status":{"state":"SUCCESS"},"plugin_result":{
              "payment_data":{"cards":[{"balance":25.5,"expiry_date":"2027-01"}]},
              "logs":{"masked_card":"•••• 7890"}
            }}
            """#),
            host: Self.host
        )

        let checkout = try makeCheckout(widgetData: widgetData(protocols: illicadoProtocols()))
        await checkout.pendingSecondaryBalanceResolution?.value

        let token = try #require(checkout.savedSecondaryTokens.first)
        #expect(token.balanceResolved)
        #expect(token.balance == 25.5)
        #expect(token.totalBalance == 25.5)
        #expect(token.disabled == nil)
    }

    // MARK: No config for this issuer

    /// `purse-creditcard` has no `SecondaryConfig` registered — the token must be dimmed
    /// immediately, with no `/init` call wasted on a partner nothing knows how to talk to.
    @Test func noRegisteredConfigMarksTheTokenInitFailedWithoutANetworkCall() async throws {
        StubURLProtocol.reset(host: Self.host)
        let token: [String: Any] = ["id": "tok-1", "value": "v1", "uniqueness_token": "u1", "pin_code": "1234"]
        let protocols = TestSessions.cardProtocol(labels: ["secondary"], integratedTokens: [token])

        let checkout = try makeCheckout(widgetData: widgetData(protocols: protocols))
        await checkout.pendingSecondaryBalanceResolution?.value

        let saved = try #require(checkout.savedSecondaryTokens.first)
        #expect(saved.disabled == .tokenInitFailed)
        // Specifically no `/init`. Creating a checkout does make one unrelated call — the server
        // clock sync — so asserting on an empty path list would pin something this test never
        // meant to be about.
        #expect(!StubURLProtocol.paths(host: Self.host).contains { $0.hasSuffix("/init") })
    }

    // MARK: A non-terminal /init failure dims only that token

    @Test func aNonTerminalInitFailureDimsOnlyThatToken() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/init", .failure(400, #"{"error":"SOME_OTHER_ERROR"}"#), host: Self.host)

        let checkout = try makeCheckout(widgetData: widgetData(protocols: illicadoProtocols()))
        await checkout.pendingSecondaryBalanceResolution?.value

        let token = try #require(checkout.savedSecondaryTokens.first)
        #expect(token.disabled == .tokenInitFailed)
        #expect(!token.balanceResolved)
        #expect(checkout.sessionState == .ready)
    }

    // MARK: A terminal /init failure ends the whole session

    /// `InitGuard.shared` remembers a terminal failure under its key indefinitely (`spent`, never
    /// evicted on failure) — reset it around this test so the poisoned key cannot fast-reject a
    /// later test that happens to build the same `(sessionId, partner, method, amount)` key.
    @Test func aTerminalInitFailureTerminatesTheSession() async throws {
        StubURLProtocol.reset(host: Self.host)
        await InitGuard.shared.reset()
        defer { Task { await InitGuard.shared.reset() } }

        StubURLProtocol.set("/init", .failure(410, #"{"error":"SESSION_EXPIRED"}"#), host: Self.host)

        let checkout = try makeCheckout(widgetData: widgetData(protocols: illicadoProtocols()))
        await checkout.pendingSecondaryBalanceResolution?.value

        #expect(checkout.sessionState == .terminated)
    }

    // MARK: setSession re-resolves the fresh, unresolved tokens it rebuilds

    @Test func setSessionReResolvesTheRebuiltSavedTokens() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set(
            "/init",
            .ok(#"{"status":{"state":"SUCCESS"},"plugin_result":{"payment_data":{"cards":[{"balance":10}]},"logs":{}}}"#),
            host: Self.host
        )

        let checkout = try makeCheckout(
            widgetData: TestSessions.widgetData(
                environment: "production",
                paymentSession: TestSessions.paymentSession(id: "session-1", amount: 100, protocols: illicadoProtocols())
            )
        )
        await checkout.pendingSecondaryBalanceResolution?.value
        #expect(checkout.savedSecondaryTokens.first?.balanceResolved == true)

        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set(
            "/init",
            .ok(#"{"status":{"state":"SUCCESS"},"plugin_result":{"payment_data":{"cards":[{"balance":30}]},"logs":{}}}"#),
            host: Self.host
        )
        try checkout.setSession(
            TestSessions.widgetData(
                environment: "production",
                paymentSession: TestSessions.paymentSession(id: "session-2", amount: 100, protocols: illicadoProtocols())
            )
        )
        // A rebuilt saved token starts unresolved again — the old balance cannot carry over, it was
        // learned against the previous session.
        #expect(checkout.savedSecondaryTokens.first?.balanceResolved == false)

        await checkout.pendingSecondaryBalanceResolution?.value
        #expect(checkout.savedSecondaryTokens.first?.balance == 30)
    }
}
