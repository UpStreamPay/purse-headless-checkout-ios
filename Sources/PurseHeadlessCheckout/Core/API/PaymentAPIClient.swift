// Web: packages/sdk/src/API/payment-api.ts
// Same: `{root}/{entityId}/sessions/{sessionId}/init|validate`, GET session, /simulation endpoints.
// Differs: async URLSession rather than a blocking HttpURLConnection the caller must offload.

import Foundation

/// Thin Payment API client. Mirrors web's `FetchPaymentAPI`: posts JSON to
/// `{apiRoot}/{entityId}/sessions/{sessionId}/<path>` with `x-api-key` auth.
public struct PaymentAPIClient: Sendable {
    private let apiKey: String
    private let root: String
    private let entityId: String
    private let sessionId: String
    private let session: URLSession

    /// - Parameter apiRoot: e.g. `https://api.purse-test.com/payment/v1`
    ///   (``PurseEnvironment/paymentAPIRoot``). A trailing slash is tolerated.
    public init(apiKey: String, apiRoot: String, entityId: String, sessionId: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.root = apiRoot.hasSuffix("/") ? String(apiRoot.dropLast()) : apiRoot
        self.entityId = entityId
        self.sessionId = sessionId
        self.session = session
    }

    /// `POST /init`. Runs under ``InitGuard``: concurrent duplicates coalesce, transient failures
    /// retry with backoff, and a terminal failure fast-rejects immediate repeats of the same call.
    public func initPayment(_ payload: [String: JSONValue]) async throws -> JSONValue {
        let key = InitGuard.key(sessionId: sessionId, payload: payload)
        return try await InitGuard.shared.run(key: key) {
            try await post("/init", body: .object(payload))
        }
    }

    /// `POST /validate` — takes a JSON *array* of items (one per method being submitted).
    /// Returns the `{results, redirection, global_status}` object.
    public func validate(_ payload: [JSONValue]) async throws -> JSONValue {
        try await post("/validate", body: .array(payload))
    }

    /// Typed `POST /validate` — serializes each ``ValidateItemPayload`` and parses the response
    /// into a ``ValidationResult``. This is what the create-payment pipeline calls.
    public func validate(items: [ValidateItemPayload]) async throws -> ValidationResult {
        let response = try await validate(items.map { $0.toJSON() })
        return ValidationResult.fromJSON(response)
    }

    /// `GET /{entityId}/sessions/{sessionId}` — every transaction made so far against this session,
    /// each with its own `status`.
    public func getSession() async throws -> [JSONValue] {
        let body = try await execute("GET", path: "", body: nil)
        guard let array = body.arrayValue else {
            throw PaymentAPIError("Payment API GET session returned a non-array body", path: "")
        }
        return array
    }

    // MARK: - Transport

    private func post(_ path: String, body: JSONValue, url: String? = nil) async throws -> JSONValue {
        try await execute("POST", path: path, body: body, url: url)
    }

    /// Session-scoped URL — every call but the simulation ones lives under the session.
    private func sessionURL(_ path: String) -> String {
        "\(root)/\(entityId)/sessions/\(sessionId)\(path)"
    }

    private func execute(_ method: String, path: String, body: JSONValue?, url: String? = nil) async throws -> JSONValue {
        let urlString = url ?? sessionURL(path)
        guard let requestURL = URL(string: urlString) else {
            throw PaymentAPIError(
                "Payment API \(method) \(path) has an unusable URL: \(urlString)",
                path: path,
                requestSent: false
            )
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try JSONEncoder().encode(body)
            } catch {
                throw PaymentAPIError(
                    "Payment API \(method) \(path) payload could not be encoded: \(error)",
                    underlying: error,
                    path: path,
                    requestSent: false
                )
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // No status at all: the request may still have reached the server. `outcomeUnknown`
            // is what tells a caller not to report this as a failed payment.
            throw PaymentAPIError(
                "Payment API \(method) \(path) failed: \(error.localizedDescription)",
                underlying: error,
                path: path
            )
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Web's FetchPaymentAPI treats status < 400 as success.
        if status >= 400 {
            // The body stays out of the message: it is partner/backend wording that ends up in
            // telemetry and merchant logs. The parsed `error` code is what a caller acts on.
            let errorCode = parseErrorCode(data)
            throw PaymentAPIError(
                "Payment API \(method) \(path) failed: HTTP \(status)" + (errorCode.map { " (\($0))" } ?? ""),
                status: status,
                errorCode: errorCode,
                path: path
            )
        }

        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw PaymentAPIError(
                "Payment API \(method) \(path) returned non-JSON: \(error)",
                underlying: error,
                path: path
            )
        }
    }

    /// The `error` code from an API JSON error body, or `nil` when the body is not that shape.
    private func parseErrorCode(_ data: Data) -> String? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return json["error"]?.stringValue?.nonBlank
    }
}
