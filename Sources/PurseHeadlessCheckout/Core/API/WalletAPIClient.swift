// Web: packages/sdk/src/API wallet client (`setWalletSession`, token edit/delete/favorite)
// Same: same routes and headers.
// Differs: a real `PATCH` — `URLSession` has no `HttpURLConnection`-style restriction against it, unlike Android, which sends `POST` + `X-HTTP-Method-Override`.

import Foundation

/// Thin Wallet API v2 client — the Swift analog of web's `FetchWalletAPI`. URLs are
/// `{walletApiRoot}/{ownerReference}/sessions/{walletSessionId}/…`, authenticated with both `x-api-
/// key` and `x-merchant-id`.
public struct WalletAPIClient: Sendable {
    /// One row of `GET /tokens` — web's `WalletItem`.
    public struct WalletToken: Sendable, Equatable {
        public let id: String
        public let name: String?
        public let favorite: Bool?
    }

    private let apiKey: String
    private let root: String
    private let ownerReference: String
    private let walletSessionId: String
    private let merchantId: String
    private let session: URLSession

    public init(
        apiKey: String,
        walletAPIRoot: String,
        ownerReference: String,
        walletSessionId: String,
        merchantId: String,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.root = walletAPIRoot.hasSuffix("/") ? String(walletAPIRoot.dropLast()) : walletAPIRoot
        self.ownerReference = ownerReference
        self.walletSessionId = walletSessionId
        self.merchantId = merchantId
        self.session = session
    }

    /// `GET /tokens?vault=…`. A non-2xx answer returns an empty list, matching web — wallet trouble
    /// must never break the checkout.
    public func getTokens(vault: Bool = true) async -> [WalletToken] {
        guard let body = try? await execute("GET", "/tokens?vault=\(vault)", body: nil) else { return [] }
        guard let array = (try? JSONDecoder().decode(JSONValue.self, from: body))?.arrayValue else { return [] }
        return array.compactMap { item in
            guard let id = item["id"]?.stringValue, !id.isEmpty else { return nil }
            return WalletToken(id: id, name: item["name"]?.stringValue, favorite: item["favorite"]?.boolValue)
        }
    }

    /// `DELETE /tokens/{id}`.
    public func deleteToken(_ tokenId: String) async throws {
        _ = try await execute("DELETE", "/tokens/\(tokenId)", body: nil)
    }

    /// `DELETE /tokens`.
    public func deleteAllTokens() async throws {
        _ = try await execute("DELETE", "/tokens", body: nil)
    }

    /// `PATCH /tokens/{id}/name` with `{name, reason}`.
    public func editTokenName(_ tokenId: String, name: String, reason: String = "") async throws {
        let body = try JSONEncoder().encode(JSONValue.object(["name": .string(name), "reason": .string(reason)]))
        _ = try await execute("PATCH", "/tokens/\(tokenId)/name", body: body)
    }

    /// `PATCH /token/{id}/favorite?favorite=…` — note web's singular `token` segment.
    public func setAsFavorite(_ tokenId: String, favorite: Bool) async throws {
        _ = try await execute("PATCH", "/token/\(tokenId)/favorite?favorite=\(favorite)", body: nil)
    }

    private func execute(_ method: String, _ path: String, body: Data?) async throws -> Data {
        let urlString = "\(root)/\(ownerReference)/sessions/\(walletSessionId)\(path)"
        guard let url = URL(string: urlString) else {
            throw PaymentAPIError("Wallet API \(method) \(path) has an unusable URL: \(urlString)", path: path)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(merchantId, forHTTPHeaderField: "x-merchant-id")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PaymentAPIError(
                "Wallet API \(method) \(path) failed: \(error.localizedDescription)",
                underlying: error,
                path: path
            )
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw PaymentAPIError(
                "Wallet API \(method) \(path) failed: HTTP \(status) \(responseBody)",
                status: status,
                path: path
            )
        }
        return data
    }
}
