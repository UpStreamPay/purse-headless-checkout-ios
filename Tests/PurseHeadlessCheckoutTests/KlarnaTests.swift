import Foundation
import Testing
@testable import PurseCheckoutKlarna
@testable import PurseHeadlessCheckout

/// Klarna's `/init` shape, what reaches `/validate`, and the authorize-callback handoff. The native
/// widget itself needs a real device and a valid client token, so it is not unit tested — the same
/// gap Card, Apple Pay and PayPal have.
@Suite(.serialized)
@MainActor
struct KlarnaTests {

    /// This suite's own host, so its stubbed /init cannot collide with another suite's.
    private static let host = "api.klarnatest.example"

    private func context(collected: [String: JSONValue] = [:]) throws -> PartnerUIContext {
        let params = try SessionCodec.decode(TestSessions.widgetData())
        return PartnerUIContext(
            partner: .klarna,
            method: .installments,
            session: params.paymentSession,
            amount: 100,
            api: PaymentAPIClient(
                apiKey: "k", apiRoot: "https://\(Self.host)/payment/v1",
                entityId: "e", sessionId: "s", session: StubURLProtocol.session()
            ),
            collected: collected
        )
    }

    // MARK: /init body

    @Test func initPayloadCarriesTheInstallmentsMethod() {
        let payload = KlarnaRequestBuilder.initPayload(amount: 42, partner: .klarna)
        #expect(payload["partner"]?.stringValue == "klarna")
        #expect(payload["method"]?.stringValue == "installments")
        #expect(payload["amount"]?.decimalValue == 42)
    }

    // MARK: Parsing /init's response

    @Test func parsesTheClientTokenFromLogs() throws {
        let response = JSONValue.object([
            "status": .object(["state": "SUCCESS"]),
            "plugin_result": .object(["logs": .object(["klarna_client_token": "jwt-token"])])
        ])
        #expect(try KlarnaRequestBuilder.parseInitConfig(response).clientToken == "jwt-token")
    }

    @Test func aRefusedInitThrows() {
        let response = JSONValue.object(["status": .object(["state": "FAILED", "description": "nope"])])
        #expect(throws: PaymentAPIError.self) { try KlarnaRequestBuilder.parseInitConfig(response) }
    }

    @Test func noClientTokenIsRefused() {
        let response = JSONValue.object([
            "status": .object(["state": "SUCCESS"]),
            "plugin_result": .object(["logs": .object([:])])
        ])
        #expect(throws: PartnerUIError.self) { try KlarnaRequestBuilder.parseInitConfig(response) }
    }

    @Test func parsesTheStepId() {
        let response = JSONValue.object(["step_id": .number("11")])
        #expect(KlarnaRequestBuilder.parseStepId(response) == 11)
    }

    @Test func aMissingStepIdParsesToNil() {
        #expect(KlarnaRequestBuilder.parseStepId(.object([:])) == nil)
    }

    // MARK: preValidation

    /// Android threads a possibly-`nil` step id through unconditionally — the API's problem to
    /// reject, not this plugin's to guard.
    @Test func preValidationCarriesWhateverStepIdWasCollected() async throws {
        let payload = try await KlarnaPlugin(partner: .klarna).preValidation(
            context(collected: [KlarnaPlugin.Collected.stepId: .number("11")])
        )
        #expect(payload.stepId == 11)
        #expect(payload.method == .installments)
    }

    @Test func preValidationToleratesNoStepIdAtAll() async throws {
        let payload = try await KlarnaPlugin(partner: .klarna).preValidation(context())
        #expect(payload.stepId == nil)
    }

    // MARK: postValidation — the authorize handoff

    @Test func postValidationSkipsAuthorizeOnAFailedResult() async throws {
        // No token registered at all — if this ran, it would throw for a missing callback.
        try await KlarnaPlugin(partner: .klarna).postValidation(.failure(), context: context())
    }

    @Test func postValidationCallsTheRegisteredCallbackAndSucceedsOnApproval() async throws {
        let token = UUID().uuidString
        await KlarnaAuthorizationRegistry.shared.register(token: token) { true }

        try await KlarnaPlugin(partner: .klarna).postValidation(
            .success(),
            context: context(collected: [KlarnaPlugin.Collected.authorizeToken: .string(token)])
        )
    }

    @Test func postValidationThrowsDeclinedWhenTheCallbackReturnsFalse() async throws {
        let token = UUID().uuidString
        await KlarnaAuthorizationRegistry.shared.register(token: token) { false }

        await #expect(throws: KlarnaAuthorizationDeclined.self) {
            try await KlarnaPlugin(partner: .klarna).postValidation(
                .success(),
                context: context(collected: [KlarnaPlugin.Collected.authorizeToken: .string(token)])
            )
        }
    }

    @Test func postValidationThrowsWhenNoWidgetWasEverPrepared() async throws {
        await #expect(throws: PartnerUIError.self) {
            try await KlarnaPlugin(partner: .klarna).postValidation(.success(), context: context())
        }
    }

    /// The registry is single-use, same as Android's `collected` entry being overwritten by the
    /// next `prepare()` — a second lookup must not find a stale callback.
    @Test func theRegistryHandsOutACallbackOnlyOnce() async throws {
        let token = UUID().uuidString
        await KlarnaAuthorizationRegistry.shared.register(token: token) { true }

        #expect(await KlarnaAuthorizationRegistry.shared.take(token) != nil)
        #expect(await KlarnaAuthorizationRegistry.shared.take(token) == nil)
    }

    // MARK: Registration

    @Test func theModuleRegistersExactlyKlarnaInstallments() throws {
        let registry = PluginRegistry()
        registry.install(KlarnaModule())

        let protocols = ["klarna": ["installments": ["configurations": ["stable": true, "labels": [], "settings": [:]]]]]
        let session = try SessionCodec.decode(
            TestSessions.widgetData(paymentSession: TestSessions.paymentSession(protocols: protocols))
        ).paymentSession

        let plugin = registry.plugin(partner: .klarna, method: .installments, session: session)
        #expect(plugin is KlarnaPlugin)
    }
}

private extension ValidationResult {
    static func success() -> ValidationResult {
        ValidationResult(globalStatus: "SUCCESS", redirection: nil, raw: .object([:]))
    }
    static func failure() -> ValidationResult {
        ValidationResult(globalStatus: "FAILED", redirection: nil, raw: .object([:]))
    }
}
