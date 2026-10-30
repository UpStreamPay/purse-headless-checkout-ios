import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// The privacy invariants, asserted against payloads the checkout **actually emits** rather than
/// against literals a test built itself.
@MainActor
@Suite(.serialized)
struct MonitoringPrivacyTests {

    private static let monitoringHost = "api.privacytest.example"
    private static let paymentHost = "api.privacypayment.example"
    /// Illicado's own PAN shape. Its last four digits are what must never appear.
    private static let pan = "9250004781234567890"

    private func makeCheckout(amount: Any = 100) throws -> PurseHeadlessCheckout {
        let protocols: [String: Any] = [
            "illicado": ["giftcard": ["configurations": [
                "stable": true, "labels": ["secondary"], "settings": [:],
            ]]],
            "purse": ["creditcard": ["configurations": [
                "stable": true,
                "labels": [],
                "settings": ["payment_min_amount": 10],
                "vault": ["vendor": "purse", "supported_brands": ["VISA"]],
            ]]],
        ]
        return try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(
                apiURL: "https://\(Self.paymentHost)/payment/v1",
                paymentSession: TestSessions.paymentSession(
                    id: "privacy-session",
                    amount: amount,
                    protocols: protocols
                )
            ),
            urlSession: StubURLProtocol.session(),
            monitoringAPIRootOverride: "https://\(Self.monitoringHost)/widget/headless_checkout"
        )
    }

    /// Every string anywhere in the posted envelopes, however deeply nested.
    private func postedStrings() throws -> [String] {
        let body = try #require(
            StubURLProtocol.body(for: "headless_checkout", host: Self.monitoringHost)?.array
        )
        var found: [String] = []
        func walk(_ value: JSONValue) {
            switch value {
            case let .string(text): found.append(text)
            case let .number(text): found.append(text)
            case let .array(values): values.forEach(walk)
            case let .object(object): object.values.forEach(walk)
            case .bool, .null: break
            }
        }
        body.forEach(walk)
        return found
    }

    /// A freshly typed secondary's id is `"{method}-{pan.suffix(4)}"`, so emitting it would hand
    /// the collector the card's last four digits.
    @Test func removingAGiftCardNeverEmitsItsPANDigits() async throws {
        StubURLProtocol.reset(host: Self.monitoringHost)
        StubURLProtocol.reset(host: Self.paymentHost)
        StubURLProtocol.set("headless_checkout", .ok("{}"), host: Self.monitoringHost)
        StubURLProtocol.set(
            "/init",
            .ok(#"{"status":{"state":"SUCCESS"},"plugin_result":{"payment_data":{"cards":[{"balance":30}]},"logs":{}}}"#),
            host: Self.paymentHost
        )

        let checkout = try makeCheckout()
        await checkout.pendingMonitoringInstall?.value

        let method = try #require(checkout.secondaryMethods.first)
        let token = try await checkout.getSecondaryToken(method: method, pan: Self.pan, cvv: "123")
        try checkout.applySecondary(token)
        checkout.removeSecondary(token)

        // `teardown()` posts PAGE_UNLOAD and flushes.
        checkout.teardown()
        try? await Task.sleep(nanoseconds: 300_000_000)

        let strings = try postedStrings()
        let lastFour = String(Self.pan.suffix(4))
        #expect(!strings.contains { $0.contains(lastFour) })
        #expect(!strings.contains { $0.contains(Self.pan) })
        // The event itself was emitted — otherwise this passes vacuously.
        #expect(strings.contains("HEADLESS_CHECKOUT_SECONDARY_TOKEN_REMOVE_FROM_SPLIT"))
    }

    /// SDK-12565: a development build gets the refusal's body on the error, to diagnose it; the
    /// message and every monitoring event still never carry it.
    @Test func anErrorBodyReachesTheErrorButNeverMonitoring() async throws {
        let marker = "holder JANE DOE is not allowed"
        StubURLProtocol.reset(host: Self.monitoringHost)
        StubURLProtocol.reset(host: Self.paymentHost)
        StubURLProtocol.set("headless_checkout", .ok("{}"), host: Self.monitoringHost)
        StubURLProtocol.set(
            "/init", .failure(400, #"{"error":"BAD_REQUEST","detail":"\#(marker)"}"#), host: Self.paymentHost
        )
        await InitGuard.shared.reset()
        defer { Task { await InitGuard.shared.reset() } }

        let checkout = try makeCheckout()
        await checkout.pendingMonitoringInstall?.value
        let method = try #require(checkout.secondaryMethods.first)

        var thrown: (any Error)?
        do {
            _ = try await checkout.getSecondaryToken(method: method, pan: Self.pan, cvv: "123")
        } catch {
            thrown = error
        }
        var apiError: PaymentAPIError?
        var current = thrown
        while let candidate = current, apiError == nil {
            apiError = candidate as? PaymentAPIError
            current = (candidate as? any PurseError)?.underlying
        }
        // The simulator is a development host.
        #expect(apiError?.responseBody?.contains(marker) == true)
        #expect(apiError?.message.contains(marker) == false)
        #expect(!String(describing: try #require(thrown)).contains(marker))

        checkout.teardown()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let strings = try postedStrings()
        #expect(!strings.contains { $0.contains(marker) })
        // The failed call was reported — otherwise this passes vacuously.
        #expect(strings.contains("HEADLESS_CHECKOUT_PARTNER_API_CALL_END"))
    }

    @Test func aReleaseBuildKeepsTheBodyOffTheError() async throws {
        StubURLProtocol.reset(host: Self.paymentHost)
        StubURLProtocol.set("/validate", .failure(400, #"{"error":"BAD_REQUEST","detail":"x"}"#), host: Self.paymentHost)
        var client = PaymentAPIClient(
            apiKey: "k", apiRoot: "https://\(Self.paymentHost)/payment/v1",
            entityId: "e", sessionId: "release-body", session: StubURLProtocol.session()
        )
        client.exposesErrorBodies = false

        await #expect {
            _ = try await client.validate([])
        } throws: { error in
            (error as? PaymentAPIError)?.responseBody == nil && (error as? PaymentAPIError)?.status == 400
        }
    }

    /// `DisabledState.message` quotes amounts; only the stable `code` may travel. Driven through a
    /// real suspension: a gift card covering all but 5 of a 100 order pushes the card method's
    /// rest-to-pay under its own `payment_min_amount`.
    @Test func aDisabledMethodEmitsItsCodeAndNotItsMessage() async throws {
        StubURLProtocol.reset(host: Self.monitoringHost)
        StubURLProtocol.reset(host: Self.paymentHost)
        StubURLProtocol.set("headless_checkout", .ok("{}"), host: Self.monitoringHost)
        StubURLProtocol.set(
            "/init",
            .ok(#"{"status":{"state":"SUCCESS"},"plugin_result":{"payment_data":{"cards":[{"balance":95}]},"logs":{}}}"#),
            host: Self.paymentHost
        )

        let checkout = try makeCheckout()
        await checkout.pendingMonitoringInstall?.value

        let method = try #require(checkout.secondaryMethods.first)
        let token = try await checkout.getSecondaryToken(method: method, pan: Self.pan, cvv: "123")
        try checkout.applySecondary(token)

        let card = try #require(checkout.paymentMethods.first { $0.id == "purse-creditcard" })
        let disabled = try #require(card.disabled)
        #expect(disabled.code == .minAmountNotMet)
        #expect(!disabled.message.isEmpty)

        checkout.teardown()
        try? await Task.sleep(nanoseconds: 300_000_000)

        let strings = try postedStrings()
        #expect(strings.contains("HEADLESS_CHECKOUT_METHOD_DISABLED"))
        #expect(strings.contains("MIN_AMOUNT_NOT_MET"))
        // The message itself, which quotes the minimum, must never travel.
        #expect(!strings.contains { $0 == disabled.message })
        #expect(!strings.contains { $0.contains(disabled.message) })
    }

    /// Android's `ApiCallMonitor`: every Payment API call is timed, by path — never by URL.
    @Test func anAPICallIsTimedByPathAndNeverByURL() async throws {
        StubURLProtocol.reset(host: Self.monitoringHost)
        StubURLProtocol.reset(host: Self.paymentHost)
        StubURLProtocol.set("headless_checkout", .ok("{}"), host: Self.monitoringHost)
        StubURLProtocol.set(
            "/init",
            .ok(#"{"status":{"state":"SUCCESS"},"plugin_result":{"payment_data":{"cards":[{"balance":30}]},"logs":{}}}"#),
            host: Self.paymentHost
        )

        let checkout = try makeCheckout()
        await checkout.pendingMonitoringInstall?.value
        let method = try #require(checkout.secondaryMethods.first)
        _ = try await checkout.getSecondaryToken(method: method, pan: Self.pan, cvv: "123")

        checkout.teardown()
        try? await Task.sleep(nanoseconds: 300_000_000)

        let strings = try postedStrings()
        #expect(strings.contains("HEADLESS_CHECKOUT_PARTNER_API_CALL_START"))
        #expect(strings.contains("HEADLESS_CHECKOUT_PARTNER_API_CALL_END"))
        #expect(strings.contains("/init"))
        #expect(!strings.contains { $0.contains(Self.paymentHost) })
    }
}
