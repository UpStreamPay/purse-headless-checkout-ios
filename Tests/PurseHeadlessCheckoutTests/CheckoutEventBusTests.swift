import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// `CheckoutEventBus`'s own contract: install, patch extras, post — one batching queue per checkout
/// instance, not a process-wide singleton (see the type's own header comment for why).
@Suite(.serialized)
@MainActor
struct CheckoutEventBusTests {

    /// A fictional host — `MonitoringAPIClient` takes any root string directly, so this suite needs
    /// no `PurseEnvironment` tier.
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

        // batchSize: 1 flushes synchronously inside post -> add -> flushNow, but the actual POST is
        // itself async; give it a moment to land.
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

    /// Later `patchExtras` calls merge onto earlier ones rather than replacing the whole set — web's
    /// `patchExtrasData`, needed because `setSession` re-stamps only `paymentSessionId`/
    /// `walletSessionId` without losing `entityId`/`version`/`wrapper` from the original `install`.
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

    /// Posting before `install` runs (a real race at construction: the install `Task` and the
    /// `CREATE`/`SET_SESSION`/`READY` posts that follow it in the same `Task` body are still async
    /// relative to the synchronous `init` returning) never crashes — the event is simply held until
    @Test func postingBeforeInstallNeverCrashes() async {
        let bus = CheckoutEventBus(batchSize: 100, flushAfterSeconds: 999)
        await bus.post(.ready)
        await bus.post(.setSession)
        await bus.flush()
    }
}
