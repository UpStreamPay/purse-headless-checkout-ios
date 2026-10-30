// Web: packages/sdk/src/API/payment-api.ts
// Same: `{root}/{entityId}/sessions/{sessionId}/init|validate`, GET session, /simulation endpoints.
// Differs: async URLSession rather than a blocking HttpURLConnection the caller must offload.

import Foundation

/// Web's `FetchPaymentAPI`: JSON to `{apiRoot}/{entityId}/sessions/{sessionId}/<path>`, `x-api-key`
/// auth.
public struct PaymentAPIClient: Sendable {
    private let apiKey: String
    private let root: String
    private let entityId: String
    private let sessionId: String
    private let session: URLSession
    /// Android's `ApiCallMonitor` listener, per client rather than process-wide: the event bus it
    /// feeds belongs to one checkout.
    var monitor: (@Sendable (CheckoutEventCode, EventLevel, JSONValue) -> Void)?
    /// Whether a refusal carries its body on ``PaymentAPIError/responseBody``.
    var exposesErrorBodies = PurseEnvironment.isDebugHost

    /// - Parameter apiRoot: ``PurseEnvironment/paymentAPIRoot``. A trailing slash is tolerated.
    public init(apiKey: String, apiRoot: String, entityId: String, sessionId: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.root = apiRoot.hasSuffix("/") ? String(apiRoot.dropLast()) : apiRoot
        self.entityId = entityId
        self.sessionId = sessionId
        self.session = session
    }

    /// `POST /init`, under ``InitGuard``.
    public func initPayment(_ payload: [String: JSONValue]) async throws -> JSONValue {
        let key = InitGuard.key(sessionId: sessionId, payload: payload)
        return try await InitGuard.shared.run(key: key) {
            try await post("/init", body: .object(payload))
        }
    }

    /// `POST /validate` — a JSON *array* of items, one per method being submitted.
    public func validate(_ payload: [JSONValue]) async throws -> JSONValue {
        try await post("/validate", body: .array(payload))
    }

    public func validate(items: [ValidateItemPayload]) async throws -> ValidationResult {
        let response = try await validate(items.map { $0.toJSON() })
        return ValidationResult.fromJSON(response)
    }

    /// Web's `FetchPaymentAPI.getSimulation`. Not session-scoped: the URL skips
    /// `/sessions/{sessionId}`.
    public func getSimulation(partner: Partner, method: PaymentMethod, product: LoanProduct) async throws -> LoanSimulation {
        let path = simulationPath(partner: partner, method: method)
        let response = try await execute("POST", path: path, body: .object(product.payload), url: "\(root)\(path)")
        guard let simulation = LoanSimulation.fromResponse(response) else {
            throw PaymentAPIError(
                "Payment API \(path) returned no usable simulation data",
                errorCode: "INVALID_LOAN_SIMULATION",
                path: path
            )
        }
        return simulation
    }

    /// Web's `getSimulationMulti`. Candidates without a `plugin_result` are skipped rather than
    /// failing the call, matching web.
    public func getSimulationMulti(
        partner: Partner, method: PaymentMethod, product: LoanProduct
    ) async throws -> [LoanSimulation] {
        let path = simulationPath(partner: partner, method: method) + "/multi"
        let response = try await execute("POST", path: path, body: .object(product.payload), url: "\(root)\(path)")
        guard let candidates = response.arrayValue else {
            throw PaymentAPIError("Payment API \(path) returned a non-array body", path: path)
        }
        return candidates.compactMap(LoanSimulation.fromResponse)
    }

    private func simulationPath(partner: Partner, method: PaymentMethod) -> String {
        "/simulation/\(entityId)/\(partner.wireValue)/\(method.wireValue)"
    }

    /// Every transaction made so far against this session, each with its own `status`.
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

    private func sessionURL(_ path: String) -> String {
        "\(root)/\(entityId)/sessions/\(sessionId)\(path)"
    }

    /// Times every call for `PARTNER_API_CALL_START`/`_END`. `path`, never the URL: the envelope
    /// already names the entity and session.
    private func execute(_ method: String, path: String, body: JSONValue?, url: String? = nil) async throws -> JSONValue {
        guard let monitor else { return try await executeUnmonitored(method, path: path, body: body, url: url) }
        monitor(.partnerAPICallStart, .network, monitoringPayload(["call": .string(method), "path": .string(path)]))
        let startedAt = ContinuousClock.now
        var success = false
        defer {
            let elapsed = ContinuousClock.now - startedAt
            let durationMs = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
            monitor(.partnerAPICallEnd, .performance, monitoringPayload([
                "call": .string(method), "path": .string(path),
                "durationMs": .number(String(durationMs)), "success": .bool(success)
            ]))
        }
        let response = try await executeUnmonitored(method, path: path, body: body, url: url)
        success = true
        return response
    }

    private func executeUnmonitored(_ method: String, path: String, body: JSONValue?, url: String? = nil) async throws -> JSONValue {
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
            // No status at all: the request may still have reached the server, so `outcomeUnknown`
            // tells the caller not to report a failed payment.
            throw PaymentAPIError(
                "Payment API \(method) \(path) failed: \(error.localizedDescription)",
                underlying: error,
                path: path
            )
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Web's FetchPaymentAPI treats status < 400 as success.
        if status >= 400 {
            // The body stays out of the message: it is partner wording that ends up in telemetry
            // and merchant logs. Callers act on the parsed `error` code; a development build also
            // gets the body itself, to diagnose the refusal.
            let errorCode = parseErrorCode(data)
            throw PaymentAPIError(
                "Payment API \(method) \(path) failed: HTTP \(status)" + (errorCode.map { " (\($0))" } ?? ""),
                status: status,
                errorCode: errorCode,
                path: path,
                responseBody: exposesErrorBodies ? String(decoding: data.prefix(4096), as: UTF8.self) : nil
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

    private func parseErrorCode(_ data: Data) -> String? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return json["error"]?.stringValue?.nonBlank
    }
}
