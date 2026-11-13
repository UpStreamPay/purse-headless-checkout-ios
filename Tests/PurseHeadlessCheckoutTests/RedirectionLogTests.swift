import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// `HEADLESS_CHECKOUT_REDIRECTION` (SDK-12712): every redirect the checkout sends the shopper on
/// is logged once, by hostname only, and the logging never stands between the shopper and the
/// redirect. Asserted on what actually reaches the collector, not on a payload built in the test.
@MainActor
@Suite(.serialized)
struct RedirectionLogTests {

    // MARK: The payload

    @Test func onlyTheHostnameIsKept() {
        #expect(redirectionHostname("https://ACS.Bank.example:8443/3ds/challenge?pareq=SECRET#frag")
            == "acs.bank.example")
        #expect(redirectionHostname("https://shop.example") == "shop.example")
    }

    @Test(arguments: ["not a url", "", "/relative/path?pareq=SECRET", "acs.bank.example/3ds"])
    func aDestinationWithNoHostIsReportedAsUnparseable(_ url: String) {
        #expect(redirectionHostname(url) == "couldn't parse the url")
    }

    @Test func aGetIsAURL() {
        let payload = redirectionPayload(
            for: .get(url: "https://acs.bank.example/3ds?pareq=SECRET", returnURLPrefix: "https://shop.example/return"),
            delegated: false
        )
        #expect(payload == .object(["url": .string("acs.bank.example"), "delegated": .bool(false)]))
    }

    @Test func aFormPostIsAnActionWithoutItsData() {
        let payload = redirectionPayload(
            for: .postForm(url: "https://acs.bank.example/challenge?txn=SECRET", formDataURLEncoded: "PaReq=SECRET"),
            delegated: true
        )
        #expect(payload == .object(["action": .string("acs.bank.example"), "delegated": .bool(true)]))
    }

    @Test func rawHTMLIsAStringFormWithoutItsMarkup() {
        let payload = redirectionPayload(
            for: .postHTML(html: #"<form action="https://acs.bank.example"><input name="PaReq" value="SECRET"></form>"#),
            delegated: false
        )
        #expect(payload == .object(["string_form": .bool(true), "delegated": .bool(false)]))
    }

    // MARK: On the wire

    /// Fictional hosts: this suite's own slice of the process-wide stub.
    private static let paymentHost = "api.redirectionlog.example"
    private static let monitoringHost = "api.redirectionlogmon.example"

    private struct StubCardPlugin: PartnerUIPlugin {
        let partner: Partner
        let method: PaymentMethod
        func preValidation(_ context: PartnerUIContext) async throws -> ValidateItemPayload {
            ItemPayload(partner: partner, method: method, amount: context.amount)
        }
    }

    private struct StubModule: PartnerModule {
        let id = "test.redirection-log.card"
        @MainActor func register(into registry: PluginRegistry) {
            registry.registerVault(vendor: .purse) { StubCardPlugin(partner: $0.partner, method: $0.method) }
        }
    }

    private final class SpyPresenter: RedirectPresenter {
        var presented: [RedirectAction] = []

        func present(_ action: RedirectAction) async throws -> RedirectOutcome {
            presented.append(action)
            return .returned(url: nil)
        }
    }

    /// What the merchant hook was handed, from its `@Sendable` closure.
    private final class HookRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var received: [RedirectAction] = []

        func record(_ action: RedirectAction) {
            lock.lock(); defer { lock.unlock() }
            received.append(action)
        }

        var actions: [RedirectAction] {
            lock.lock(); defer { lock.unlock() }
            return received
        }
    }

    private static let sessionURLs: [String: Any] = [
        "success": "https://shop.example/success?order=SECRET",
        "failure": "https://shop.example/failure?order=SECRET",
        "redirection": "https://shop.example/return",
    ]

    private func submittedCheckout(
        validate body: String,
        collector: StubURLProtocol.Response = .ok("{}"),
        hooks: PurseCheckoutHooks? = nil,
        sessionURLs: [String: Any] = [:]
    ) async throws -> (PurseHeadlessCheckout, ValidationResult) {
        StubURLProtocol.reset(host: Self.paymentHost)
        StubURLProtocol.reset(host: Self.monitoringHost)
        StubURLProtocol.set("/validate", .ok(body), host: Self.paymentHost)
        StubURLProtocol.set("headless_checkout", collector, host: Self.monitoringHost)

        let registry = PluginRegistry()
        registry.install(StubModule())
        let checkout = try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(
                apiURL: "https://\(Self.paymentHost)/payment/v1",
                paymentSession: TestSessions.paymentSession(
                    id: "redirection-log-session", amount: 100, extra: sessionURLs
                )
            ),
            hooks: hooks,
            registry: registry,
            urlSession: StubURLProtocol.session(),
            monitoringAPIRootOverride: "https://\(Self.monitoringHost)/widget/headless_checkout",
            serverClockOverride: ServerDatetimeChecker(fetchServerTime: { Date() })
        )
        await checkout.pendingMonitoringInstall?.value

        let method = try #require(checkout.paymentMethods.compactMap { item -> PrimaryMethod? in
            if case let .primaryMethod(method) = item { return method }
            return nil
        }.first)
        try checkout.setPrimary(method)
        return (checkout, try await checkout.submitPayment())
    }

    /// Every event the collector received for this checkout, once `teardown()` has flushed.
    private func postedEvents(_ checkout: PurseHeadlessCheckout) async throws -> [JSONValue] {
        await checkout.pendingRedirectionLog?.value
        checkout.teardown()
        for _ in 0..<60 {
            let events = StubURLProtocol.bodies(for: "headless_checkout", host: Self.monitoringHost)
                .flatMap { $0.array ?? [] }
                .compactMap { $0["event"] }
            if events.contains(where: { $0["code"]?.stringValue == "HEADLESS_CHECKOUT_PAGE_UNLOAD" }) {
                return events
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("teardown never flushed the monitoring queue")
        return []
    }

    private func redirectionPayloads(_ checkout: PurseHeadlessCheckout) async throws -> [JSONValue] {
        try await postedEvents(checkout)
            .filter { $0["code"]?.stringValue == "HEADLESS_CHECKOUT_REDIRECTION" }
            .map {
                #expect($0["type"]?.stringValue == "INFO")
                return $0["payload"] ?? .null
            }
    }

    /// Every string in `value`, however deeply nested.
    private func strings(in value: JSONValue) -> [String] {
        switch value {
        case let .string(text): [text]
        case let .number(text): [text]
        case let .array(values): values.flatMap(strings(in:))
        case let .object(object): object.values.flatMap(strings(in:))
        case .bool, .null: []
        }
    }

    private static let threeDSRedirect =
        #"{"global_status":"WAITING","results":[],"redirection":{"url":"https://acs.bank.example/3ds?pareq=SECRET"}}"#

    @Test func aRedirectTheSDKPresentsIsLoggedAsNotDelegated() async throws {
        let (checkout, result) = try await submittedCheckout(validate: Self.threeDSRedirect)
        let presenter = SpyPresenter()

        let outcome = try await checkout.presentRedirectIfNeeded(for: result, using: presenter)

        #expect(outcome == .returned(url: nil))
        #expect(presenter.presented == [.get(url: "https://acs.bank.example/3ds?pareq=SECRET")])
        let payloads = try await redirectionPayloads(checkout)
        #expect(payloads == [.object(["url": .string("acs.bank.example"), "delegated": .bool(false)])])
        #expect(!payloads.flatMap(strings(in:)).contains { $0.contains("SECRET") || $0.contains("/3ds") })
    }

    /// The hook gets the very action it got before, and taking it over is a delegation.
    @Test func aHookThatTakesTheRedirectOverIsLoggedAsDelegated() async throws {
        let recorder = HookRecorder()
        let hooks = PurseCheckoutHooks(onRedirection: { action in
            recorder.record(action)
            return true
        })
        let (checkout, result) = try await submittedCheckout(validate: Self.threeDSRedirect, hooks: hooks)
        let presenter = SpyPresenter()

        let outcome = try await checkout.presentRedirectIfNeeded(for: result, using: presenter)

        #expect(outcome == nil)
        #expect(presenter.presented.isEmpty)
        #expect(recorder.actions == [.get(url: "https://acs.bank.example/3ds?pareq=SECRET")])
        #expect(recorder.actions == [checkout.pendingRedirect(for: result)])
        #expect(try await redirectionPayloads(checkout)
            == [.object(["url": .string("acs.bank.example"), "delegated": .bool(true)])])
    }

    /// Declining hands the redirect back to the SDK: one event, and not a delegation.
    @Test func aHookThatDeclinesIsLoggedOnceAsNotDelegated() async throws {
        let recorder = HookRecorder()
        let hooks = PurseCheckoutHooks(onRedirection: { action in
            recorder.record(action)
            return false
        })
        let (checkout, result) = try await submittedCheckout(validate: Self.threeDSRedirect, hooks: hooks)
        let presenter = SpyPresenter()

        _ = try await checkout.presentRedirectIfNeeded(for: result, using: presenter)

        #expect(recorder.actions == presenter.presented)
        #expect(presenter.presented == [.get(url: "https://acs.bank.example/3ds?pareq=SECRET")])
        #expect(try await redirectionPayloads(checkout)
            == [.object(["url": .string("acs.bank.example"), "delegated": .bool(false)])])
    }

    /// A throwing hook sends the shopper nowhere: the hook error is what gets reported.
    @Test func aThrowingHookLogsNoRedirection() async throws {
        struct HookError: Error {}
        let hooks = PurseCheckoutHooks(onRedirection: { _ in throw HookError() })
        let (checkout, result) = try await submittedCheckout(validate: Self.threeDSRedirect, hooks: hooks)
        let presenter = SpyPresenter()

        await #expect(throws: PurseCheckoutError.self) {
            try await checkout.presentRedirectIfNeeded(for: result, using: presenter)
        }

        #expect(presenter.presented.isEmpty)
        let codes = try await postedEvents(checkout).compactMap { $0["code"]?.stringValue }
        #expect(!codes.contains("HEADLESS_CHECKOUT_REDIRECTION"))
        #expect(codes.contains("HEADLESS_CHECKOUT_CLIENT_HOOK_ERROR"))
    }

    /// A per-item form POST: the destination is an `action`, its form data never leaves the device.
    @Test func aFormPostIsLoggedAsAnAction() async throws {
        let body = #"""
        {"global_status":"WAITING","results":[{"partner":"purse","method":"creditcard","status":{"state":"WAITING"},
        "plugin_result":{"logs":{"redirection_url":"https://acs.bank.example/challenge?txn=SECRET","redirection_json":"PaReq=SECRET&MD=SECRET"}}}]}
        """#
        let (checkout, result) = try await submittedCheckout(validate: body)
        let presenter = SpyPresenter()

        _ = try await checkout.presentRedirectIfNeeded(for: result, using: presenter)

        #expect(presenter.presented == [.postForm(
            url: "https://acs.bank.example/challenge?txn=SECRET", formDataURLEncoded: "PaReq=SECRET&MD=SECRET"
        )])
        let payloads = try await redirectionPayloads(checkout)
        #expect(payloads == [.object(["action": .string("acs.bank.example"), "delegated": .bool(false)])])
        #expect(!payloads.flatMap(strings(in:)).contains { $0.contains("SECRET") })
    }

    /// Raw HTML from the API: flagged, never copied.
    @Test func aRawHTMLFormIsLoggedAsAStringForm() async throws {
        let body = #"""
        {"global_status":"WAITING","results":[],"redirection":{"form":"<form action=\"https://acs.bank.example\" method=\"post\"><input name=\"PaReq\" value=\"SECRET\"></form>"}}
        """#
        let (checkout, result) = try await submittedCheckout(validate: body)
        let presenter = SpyPresenter()

        _ = try await checkout.presentRedirectIfNeeded(for: result, using: presenter)

        #expect(presenter.presented.count == 1)
        let payloads = try await redirectionPayloads(checkout)
        #expect(payloads == [.object(["string_form": .bool(true), "delegated": .bool(false)])])
        #expect(!payloads.flatMap(strings(in:)).contains { $0.contains("SECRET") || $0.contains("acs.bank") })
    }

    /// Web's `onValidateError`: a refused payment sends the shopper to the session's failure page.
    @Test func aRefusedPaymentRedirectIsLogged() async throws {
        let (checkout, result) = try await submittedCheckout(
            validate: #"{"global_status":"FAILED","results":[{"partner":"purse","method":"creditcard","status":{"state":"FAILED"}}]}"#,
            sessionURLs: Self.sessionURLs
        )
        let presenter = SpyPresenter()

        _ = try await checkout.presentRedirectIfNeeded(for: result, using: presenter)

        #expect(presenter.presented == [.get(
            url: "https://shop.example/failure?order=SECRET", returnURLPrefix: "https://shop.example/return"
        )])
        let payloads = try await redirectionPayloads(checkout)
        #expect(payloads == [.object(["url": .string("shop.example"), "delegated": .bool(false)])])
        #expect(!payloads.flatMap(strings(in:)).contains { $0.contains("SECRET") || $0.contains("failure") })
    }

    /// A destination the log cannot read still reaches the presenter, untouched.
    @Test func anUnparseableURLIsStillPresented() async throws {
        let (checkout, result) = try await submittedCheckout(
            validate: #"{"global_status":"WAITING","results":[],"redirection":{"url":"not a url"}}"#
        )
        let presenter = SpyPresenter()

        _ = try await checkout.presentRedirectIfNeeded(for: result, using: presenter)

        #expect(presenter.presented == [.get(url: "not a url")])
        #expect(try await redirectionPayloads(checkout)
            == [.object(["url": .string("couldn't parse the url"), "delegated": .bool(false)])])
    }

    /// The collector failing changes nothing for the shopper.
    @Test func aFailingCollectorDoesNotBlockTheRedirect() async throws {
        let (checkout, result) = try await submittedCheckout(
            validate: Self.threeDSRedirect, collector: .failure(500)
        )
        let presenter = SpyPresenter()

        let outcome = try await checkout.presentRedirectIfNeeded(for: result, using: presenter)

        #expect(outcome == .returned(url: nil))
        #expect(presenter.presented.count == 1)
        #expect(try await redirectionPayloads(checkout).count == 1)
    }

    /// Nothing to leave for, nothing logged.
    @Test func noRedirectNoEvent() async throws {
        let (checkout, result) = try await submittedCheckout(validate: #"{"global_status":"SUCCESS","results":[]}"#)

        #expect(try await checkout.presentRedirectIfNeeded(for: result, using: SpyPresenter()) == nil)
        #expect(try await redirectionPayloads(checkout).isEmpty)
    }
}
