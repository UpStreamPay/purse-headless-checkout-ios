// Web: packages/sdk/src/API wallet client (`setWalletSession`, token edit/delete/favorite)
// Same: same routes and headers.
// Differs: a real `PATCH` — `URLSession` has no `HttpURLConnection` restriction against it, unlike Android, which sends `POST` + `X-HTTP-Method-Override`.

import Foundation

/// Web's `FetchWalletAPI`. URLs are `{walletApiRoot}/{ownerReference}/sessions/{walletSessionId}/…`,
/// authenticated with `x-api-key` and `x-merchant-id`.
public struct WalletAPIClient: Sendable {
    /// Web's `WalletItem`.
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

    /// A non-2xx answer returns an empty list, matching web: wallet trouble must never break the
    /// checkout.
    public func getTokens(vault: Bool = true) async -> [WalletToken] {
        guard let body = try? await execute("GET", "/tokens?vault=\(vault)", body: nil) else { return [] }
        guard let array = (try? JSONDecoder().decode(JSONValue.self, from: body))?.arrayValue else { return [] }
        return array.compactMap { item in
            guard let id = item["id"]?.stringValue, !id.isEmpty else { return nil }
            return WalletToken(id: id, name: item["name"]?.stringValue, favorite: item["favorite"]?.boolValue)
        }
    }

    public func deleteToken(_ tokenId: String) async throws {
        _ = try await execute("DELETE", "/tokens/\(tokenId)", body: nil)
    }

    public func deleteAllTokens() async throws {
        _ = try await execute("DELETE", "/tokens", body: nil)
    }

    public func editTokenName(_ tokenId: String, name: String, reason: String = "") async throws {
        let body = try JSONEncoder().encode(JSONValue.object(["name": .string(name), "reason": .string(reason)]))
        _ = try await execute("PATCH", "/tokens/\(tokenId)/name", body: body)
    }

    /// Note web's singular `token` segment here.
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
            // The body stays out of the message: it reaches monitoring events, and a wallet 4xx body
            // can carry a masked PAN or a holder name.
            let errorCode = (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"]?.stringValue
            throw PaymentAPIError(
                "Wallet API \(method) \(path) failed: HTTP \(status)" + (errorCode.map { " (\($0))" } ?? ""),
                status: status,
                errorCode: errorCode,
                path: path
            )
        }
        return data
    }
}
