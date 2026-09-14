import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// Wallet token management — rename, delete, favorite, delete-all — and the label rules that gate
/// them. Uses its own fictional Wallet API root (`walletAPIRootOverride`), independent of the
/// `PurseEnvironment` tier the session declares, so this suite claims no tier at all.
@MainActor
@Suite(.serialized)
struct WalletTests {

    private static let host = "api.wallettest.example"

    private func checkout() throws -> PurseHeadlessCheckout {
        let token: [String: Any] = ["id": "tok-1", "value": "v1", "description": ["masked_pan": "•••• 1111"]]
        return try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(
                paymentSession: TestSessions.paymentSession(protocols: TestSessions.cardProtocol(integratedTokens: [token])),
                walletSession: ["session_id": "wallet-1", "owner_reference": "owner-1", "merchant": "merchant-1"]
            ),
            urlSession: StubURLProtocol.session(),
            walletAPIRootOverride: "https://\(Self.host)/wallet/v2"
        )
    }

    private func paymentToken(_ checkout: PurseHeadlessCheckout) throws -> PaymentToken {
        try #require(checkout.paymentTokens.first)
    }

    // MARK: WalletAPIClient — the real transport

    @Test func getTokensParsesTheListAndReturnsEmptyOnFailure() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set(
            "/tokens", .ok(#"[{"id":"a","name":"My card","favorite":true},{"id":"b"}]"#), host: Self.host
        )
        let client = WalletAPIClient(
            apiKey: "k", walletAPIRoot: "https://\(Self.host)/wallet/v2",
            ownerReference: "o", walletSessionId: "s", merchantId: "m", session: StubURLProtocol.session()
        )
        let tokens = await client.getTokens()
        #expect(tokens.count == 2)
        #expect(tokens[0].name == "My card")
        #expect(tokens[0].favorite == true)
        #expect(tokens[1].name == nil)

        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/tokens", .failure(500), host: Self.host)
        #expect(await client.getTokens().isEmpty)
    }

    /// `URLSession` has no `HttpURLConnection`-style restriction against `PATCH` — a real one goes
    /// on the wire, not `POST` + `X-HTTP-Method-Override` the way Android sends it.
    @Test func editTokenNameSendsARealPATCH() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/tokens/tok-1/name", .ok("{}"), host: Self.host)
        let client = WalletAPIClient(
            apiKey: "k", walletAPIRoot: "https://\(Self.host)/wallet/v2",
            ownerReference: "o", walletSessionId: "s", merchantId: "m", session: StubURLProtocol.session()
        )
        try await client.editTokenName("tok-1", name: "Holiday card")
        let body = try #require(StubURLProtocol.body(for: "/tokens/tok-1/name", host: Self.host)?.object)
        #expect(body["name"]?.stringValue == "Holiday card")
    }

    // MARK: Label validation

    private func walletTokens() throws -> WalletTokens {
        let params = try SessionCodec.decode(TestSessions.widgetData())
        return WalletTokens(params: params, walletAPIRoot: "https://\(Self.host)/wallet/v2", urlSession: StubURLProtocol.session())
    }

    @Test func validateLabelRejectsAnythingOutsideTheAllowedPattern() throws {
        let tokens = try walletTokens()
        #expect(throws: PurseCheckoutError.self) {
            try tokens.validateLabel("bad!name", takenNames: [], excludingTokenId: nil)
        }
        #expect(throws: Never.self) {
            try tokens.validateLabel("Good Name 2", takenNames: [], excludingTokenId: nil)
        }
    }

    @Test func validateLabelRejectsATakenName() throws {
        let tokens = try walletTokens()
        do {
            try tokens.validateLabel("Taken", takenNames: ["Taken"], excludingTokenId: nil)
            Issue.record("expected a taken name to be refused")
        } catch let error as PurseCheckoutError {
            #expect(error.code == .tokenNameExists)
        }
    }

    // MARK: PurseHeadlessCheckout wallet operations

    @Test func editTokenRenamesTheItemInPlace() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/tokens", .ok(#"[{"id":"tok-1"}]"#), host: Self.host)
        StubURLProtocol.set("/tokens/tok-1/name", .ok("{}"), host: Self.host)

        let checkout = try checkout()
        await checkout.pendingWalletSync?.value
        let token = try paymentToken(checkout)

        try await checkout.editToken(token, name: "Holiday card")
        #expect(checkout.paymentTokens.first?.name == "Holiday card")
    }

    @Test func editTokenRequiresTheTokenToBeInTheWallet() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/tokens", .ok("[]"), host: Self.host)

        let checkout = try checkout()
        await checkout.pendingWalletSync?.value
        let token = try paymentToken(checkout)

        do {
            try await checkout.editToken(token, name: "Anything")
            Issue.record("expected a missing wallet token to be refused")
        } catch let error as PurseCheckoutError {
            #expect(error.code == .missingToken)
        }
    }

    @Test func deleteTokenRemovesItFromTheListAndTheSplit() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/tokens", .ok(#"[{"id":"tok-1"}]"#), host: Self.host)
        StubURLProtocol.set("/tokens/tok-1", .ok("{}"), host: Self.host)

        let checkout = try checkout()
        await checkout.pendingWalletSync?.value
        let token = try paymentToken(checkout)
        try checkout.setPrimaryToken(token)

        try await checkout.deleteToken(token)
        #expect(checkout.paymentTokens.isEmpty)
        #expect(checkout.amountSplit.isEmpty)
    }

    @Test func setTokenFavoriteTogglesOptimisticallyAndRevertsOnFailure() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/tokens", .ok(#"[{"id":"tok-1"}]"#), host: Self.host)
        StubURLProtocol.set("/token/tok-1/favorite", .failure(500), host: Self.host)

        let checkout = try checkout()
        await checkout.pendingWalletSync?.value
        let token = try paymentToken(checkout)
        #expect(!token.favorite)

        await #expect(throws: PaymentAPIError.self) { try await checkout.setTokenFavorite(token) }
        // Reverted after the failure — never left toggled on a call that didn't actually persist.
        #expect(checkout.paymentTokens.first?.favorite == false)
    }

    @Test func deleteAllTokensClearsSavedInstrumentsAndTheWallet() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/tokens", .ok(#"[{"id":"tok-1"}]"#), host: Self.host)

        let checkout = try checkout()
        await checkout.pendingWalletSync?.value

        try await checkout.deleteAllTokens()
        #expect(checkout.paymentTokens.isEmpty)
    }

    @Test func aMissingWalletSessionRefusesEveryOperation() async throws {
        // No wallet_session attached — a checkout with none never calls the Wallet API at all.
        let checkout = try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(),
            urlSession: StubURLProtocol.session()
        )
        do {
            try await checkout.deleteAllTokens()
            Issue.record("expected a missing wallet session to be refused")
        } catch let error as PurseCheckoutError {
            #expect(error.code == .missingWalletSession)
        }
    }
}
