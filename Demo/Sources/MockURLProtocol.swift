import Foundation

/// Stubs the Payment API's `/validate` when the Demo runs against its canned session.
final class MockURLProtocol: URLProtocol {
    struct MockResponse {
        let data: Data
        let statusCode: Int
    }
    // Single-threaded demo, no real concurrent access — set once at launch, read from URLProtocol
    // callbacks that never overlap here.
    nonisolated(unsafe) static var handlers: [String: MockResponse] = [:]

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let key = Self.handlers.keys.first { path.hasSuffix($0) } ?? ""
        guard let mock = Self.handlers[key] else {
            // Not `.notConnectedToInternet`: that is code -1009, which URLSession logs as if the
            // device were offline, and reads that way to anyone looking at the console.
            client?.urlProtocol(self, didFailWithError: URLError(
                .unsupportedURL,
                userInfo: [NSLocalizedDescriptionKey: "MockURLProtocol has no handler for \(path)"]
            ))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: mock.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: mock.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
