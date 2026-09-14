import Foundation
@testable import PurseHeadlessCheckout

/// A `URLProtocol` stub, the same test-double shape `purse-ios-securefields` uses. Handlers are
/// keyed by path suffix (`"/validate"`, `"/init"`).
final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    struct Response {
        let status: Int
        let body: String

        static func ok(_ body: String) -> Response { Response(status: 200, body: body) }
        static func failure(_ status: Int, _ body: String = "{}") -> Response { Response(status: status, body: body) }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Response] = [:]
    nonisolated(unsafe) private static var requestedPaths: [String] = []
    nonisolated(unsafe) private static var bodies: [String: Data] = [:]

    static func set(_ suffix: String, _ response: Response) {
        lock.lock(); defer { lock.unlock() }
        handlers[suffix] = response
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handlers.removeAll()
        requestedPaths.removeAll()
        bodies.removeAll()
    }

    /// Paths requested so far, in order — lets a test assert a call did *not* happen.
    static var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return requestedPaths
    }

    /// The body posted to the first request whose path ends with `suffix`.
    static func body(for suffix: String) -> JSONValueBox? {
        lock.lock(); defer { lock.unlock() }
        guard let data = bodies[suffix] else { return nil }
        return JSONValueBox(data: data)
    }

    /// A URLSession wired to this stub.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.requestedPaths.append(path)
        let match = Self.handlers.first { path.hasSuffix($0.key) }
        // URLProtocol strips httpBody for streamed uploads; read the stream when that happens.
        if let suffix = match?.key {
            if let body = request.httpBody {
                Self.bodies[suffix] = body
            } else if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                stream.close()
                Self.bodies[suffix] = data
            }
        }
        Self.lock.unlock()

        guard let response = match?.value, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        let httpResponse = HTTPURLResponse(
            url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A decoded request body, for asserting what actually went on the wire.
struct JSONValueBox {
    let data: Data

    var array: [JSONValue]? { try? JSONDecoder().decode([JSONValue].self, from: data) }
    var object: JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: data) }
}
