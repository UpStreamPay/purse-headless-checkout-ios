import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// `CheckoutEventBus`'s own contract: install, patch extras, post — one batching queue per checkout
/// instance, not a process-wide singleton (see the type's own header comment for why).
@Suite(.serialized)
@MainActor
struct CheckoutEventBusTests {

    /// `MonitoringAPIClient` takes any root string, so this suite needs no `PurseEnvironment` tier.
    private static let host = "api.monitoringtest.example"

    @Test func aPostedEventReachesTheClientWithTheEnvelopeExtras() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("headless_checkout", .ok("{}"), host: Self.host)

        let bus = CheckoutEventBus(batchSize: 1, flushAfterSeconds: 999)
        let client = MonitoringAPIClient(
            apiKey: "k", monitoringAPIRoot: "https://\(Self.host)/widget/headless_checkout", envWireValue: "sandbox",
            session: StubURLProtocol.session()
        )
        await bus.install(client: client, instanceId: "instance-1")
        await bus.patchExtras(entityId: "entity-1", paymentSessionId: "session-1", version: "1.2.3", wrapper: "direct")
        await bus.post(.ready)

        // batchSize 1 flushes inside `post`, but the POST itself is async; give it a moment.
        try? await Task.sleep(nanoseconds: 100_000_000)

        let body = try #require(StubURLProtocol.body(for: "headless_checkout", host: Self.host)?.array)
        let message = try #require(body.first)
        #expect(message["instanceId"]?.stringValue == "instance-1")
        #expect(message["entityId"]?.stringValue == "entity-1")
        #expect(message["paymentSessionId"]?.stringValue == "session-1")
        #expect(message["version"]?.stringValue == "1.2.3")
        #expect(message["wrapper"]?.stringValue == "direct")
        #expect(message["env"]?.stringValue == "sandbox")
        #expect(message["platform"]?.stringValue == "ios")
        #expect(message["event"]?["code"]?.stringValue == "HEADLESS_CHECKOUT_READY")
    }

    /// `patchExtras` merges rather than replaces: `setSession` re-stamps only the session ids and
    /// must not lose `entityId`/`version`/`wrapper` from `install`.
    @Test func patchExtrasMergesRatherThanReplaces() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("headless_checkout", .ok("{}"), host: Self.host)

        let bus = CheckoutEventBus(batchSize: 1, flushAfterSeconds: 999)
        let client = MonitoringAPIClient(
            apiKey: "k", monitoringAPIRoot: "https://\(Self.host)/widget/headless_checkout", envWireValue: "sandbox",
            session: StubURLProtocol.session()
        )
        await bus.install(client: client, instanceId: "instance-1")
        await bus.patchExtras(entityId: "entity-1", version: "1.2.3", wrapper: "direct")
        await bus.patchExtras(paymentSessionId: "session-2")
        await bus.post(.ready)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let body = try #require(StubURLProtocol.body(for: "headless_checkout", host: Self.host)?.array)
        let message = try #require(body.first)
        #expect(message["entityId"]?.stringValue == "entity-1")
        #expect(message["version"]?.stringValue == "1.2.3")
        #expect(message["paymentSessionId"]?.stringValue == "session-2")
    }

    /// A real race at construction: `init` returns synchronously while the install `Task` and the
    /// posts following it are still pending.
    @Test func postingBeforeInstallNeverCrashes() async {
        let bus = CheckoutEventBus(batchSize: 100, flushAfterSeconds: 999)
        await bus.post(.ready)
        await bus.post(.setSession)
        await bus.flush()
    }
}
