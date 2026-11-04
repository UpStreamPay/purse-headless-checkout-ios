// Web: packages/headless-checkout/src/utils/error/error.ts (`PurseHeadlessCheckoutError`)
// Same: one root for every SDK error, each carrying a stable code and its documentation link.
// Differs: a protocol, not an abstract class — so session, API and checkout errors stay distinct enums a caller can switch over.

import Foundation

/// The root every error this SDK raises conforms to.
public protocol PurseError: Error, CustomStringConvertible {
    var code: PurseErrorCode { get }
    /// Human-readable detail. Never contains card data or partner body text.
    var message: String { get }
    var underlying: (any Error)? { get }
}

public extension PurseError {
    var underlying: (any Error)? { nil }

    var documentationLink: String { code.documentationLink }

    var description: String { "[\(code.rawValue)] \(message)" }
}

/// Web's `SESSION_MALFORMED`: the session payload itself, not a network failure
/// (``PaymentAPIError``).
public enum PurseSessionError: PurseError {
    case sessionMalformed(String)
    /// A `.test` or `.development` session in a release-signed app.
    case environmentNotAllowed(PurseEnvironment)

    public var code: PurseErrorCode {
        switch self {
        case .sessionMalformed: .sessionMalformed
        case .environmentNotAllowed: .environmentNotAllowed
        }
    }

    public var message: String {
        switch self {
        case let .sessionMalformed(detail): detail
        case let .environmentNotAllowed(environment):
            "PurseEnvironment.\(environment.rawValue) is internal and not allowed in a release-signed app: "
                + "create the session on sandbox or production"
        }
    }
}
