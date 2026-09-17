// Web: packages/sdk/src/server-datetime-checker.ts (`GET /datetime`)
// Same: same endpoint.
// Differs: async URLSession.

import Foundation

/// Web's `FetchDatetimeAPI`: unversioned root, `x-api-key` auth, `{ "iso": "..." }` response.
public struct DatetimeAPIClient: Sendable {
    private let apiKey: String
    private let root: String
    private let session: URLSession

    public init(apiKey: String, datetimeAPIRoot: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.root = datetimeAPIRoot.hasSuffix("/") ? String(datetimeAPIRoot.dropLast()) : datetimeAPIRoot
        self.session = session
    }

    /// - Throws: ``PaymentAPIError`` on transport, HTTP or parse failure.
    public func datetime() async throws -> Date {
        guard let url = URL(string: root) else {
            throw PaymentAPIError("Datetime root is not a usable URL: \(root)", path: "/datetime")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PaymentAPIError(
                "Datetime call failed: \(error.localizedDescription)",
                underlying: error,
                path: "/datetime"
            )
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 {
            throw PaymentAPIError("Datetime call failed: HTTP \(status)", status: status, path: "/datetime")
        }

        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let iso = json["iso"]?.stringValue,
              let date = ISO8601Date.parse(iso)
        else {
            throw PaymentAPIError("Datetime call returned an unusable body", path: "/datetime")
        }
        return date
    }
}
