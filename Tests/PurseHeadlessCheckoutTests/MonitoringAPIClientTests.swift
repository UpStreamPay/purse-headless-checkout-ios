import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// The envelope shape, and the no-op-without-an-api-key rule that keeps a monitoring-disabled
/// checkout fully usable.
@Suite(.serialized)
struct MonitoringAPIClientTests {

    private static let host = "api.monitoringclienttest.example"

    private func client(apiKey: String = "k") -> MonitoringAPIClient {
        MonitoringAPIClient(
            apiKey: apiKey,
            monitoringAPIRoot: "https://\(Self.host)/widget/headless_checkout",
            envWireValue: "test",
            session: StubURLProtocol.session()
        )
    }

    @Test func sendLogsIsANoOpWithoutAnAPIKey() async {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("headless_checkout", .ok("{}"), host: Self.host)

        await client(apiKey: "").sendLogs([.object(["code": "HEADLESS_CHECKOUT_READY"])], instanceId: "i", extras: [:])
        #expect(StubURLProtocol.paths(host: Self.host).isEmpty)
    }

    @Test func sendLogsIsANoOpWithNoEvents() async {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("headless_checkout", .ok("{}"), host: Self.host)

        await client().sendLogs([], instanceId: "i", extras: [:])
        #expect(StubURLProtocol.paths(host: Self.host).isEmpty)
    }

    @Test func sendLogsPostsEveryEventWrappedInTheEnvelope() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("headless_checkout", .ok("{}"), host: Self.host)

        await client().sendLogs(
            [.object(["code": "HEADLESS_CHECKOUT_READY"]), .object(["code": "HEADLESS_CHECKOUT_SET_SESSION"])],
            instanceId: "instance-1",
            extras: ["entityId": .string("entity-1")]
        )

        let body = try #require(StubURLProtocol.body(for: "headless_checkout", host: Self.host)?.array)
        #expect(body.count == 2)
        #expect(body[0]["instanceId"]?.stringValue == "instance-1")
        #expect(body[0]["entityId"]?.stringValue == "entity-1")
        #expect(body[0]["platform"]?.stringValue == "ios")
        #expect(body[0]["env"]?.stringValue == "test")
        #expect(body[1]["event"]?["code"]?.stringValue == "HEADLESS_CHECKOUT_SET_SESSION")
    }

    @Test func theAPIKeyTravelsAsAQueryParameterNotInTheBody() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("headless_checkout", .ok("{}"), host: Self.host)

        await client(apiKey: "secret-key").sendLogs(
            [.object(["code": "HEADLESS_CHECKOUT_READY"])], instanceId: "i", extras: [:]
        )
        let body = try #require(StubURLProtocol.body(for: "headless_checkout", host: Self.host)?.array)
        #expect(!body.contains { $0.objectValue?.values.contains { $0.stringValue == "secret-key" } == true })
    }
}
