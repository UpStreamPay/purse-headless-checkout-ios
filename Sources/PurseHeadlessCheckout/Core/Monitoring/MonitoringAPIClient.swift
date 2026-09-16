// Web: packages/sdk `ApiLogger` (`/widget/headless_checkout`)
// Same: same route and message envelope.
// Differs: `platform: "ios"` on every message; `async` `URLSession` fire-and-forget instead of a dedicated daemon thread.

import Foundation

/// Ships monitoring event batches to `POST {root}?api-key=…`. Each event is wrapped in the same
/// message envelope web uses: `{event, instanceId, entityId?, paymentSessionId?, walletSessionId?,
/// version?, wrapper?, env, platform}` — plus the `platform` the native vault SDKs already send.
public struct MonitoringAPIClient: Sendable {
    private let apiKey: String
    private let root: String
    private let envWireValue: String
    private let platform: String
    private let session: URLSession

    public init(
        apiKey: String,
        monitoringAPIRoot: String,
        envWireValue: String,
        platform: String = "ios",
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.root = monitoringAPIRoot.hasSuffix("/") ? String(monitoringAPIRoot.dropLast()) : monitoringAPIRoot
        self.envWireValue = envWireValue
        self.platform = platform
        self.session = session
    }

    /// Queue `events` (each already serialized) for an async POST, stamped with `instanceId` and
    /// whatever `extras` the checkout has patched on (entity id, session ids, version, wrapper).
    public func sendLogs(_ events: [JSONValue], instanceId: String, extras: [String: JSONValue]) async {
        guard !apiKey.isEmpty, !events.isEmpty else { return }

        let body: [JSONValue] = events.map { event in
            var message = extras
            message["event"] = event
            message["instanceId"] = .string(instanceId)
            message["env"] = .string(envWireValue)
            message["platform"] = .string(platform)
            return .object(message)
        }

        guard var components = URLComponents(string: root) else { return }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "api-key", value: apiKey)]
        guard let url = components.url, let data = try? JSONEncoder().encode(JSONValue.array(body)) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        // Web posts the batch as a text/plain Blob (sendBeacon's CORS-safe type); match it.
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        _ = try? await session.data(for: request)
    }
}
