// Web: packages/headless-checkout/src/utils/error/error.ts (`PurseHeadlessCheckoutError`)
// Same: one root for every SDK error, each carrying a stable code and its documentation link.
// Differs: a protocol rather than an abstract class — Swift errors are values, and this lets the session, API and checkout error types stay distinct enums a caller can switch over.

import Foundation

/// The root every error this SDK raises conforms to — session decoding (``PurseSessionError``),
/// Payment API transport (``PaymentAPIError``) and checkout orchestration.
public protocol PurseError: Error, CustomStringConvertible {
    /// The machine-readable reason — the same vocabulary as web's `PurseHeadlessCheckoutErrors`.
    var code: PurseErrorCode { get }
    /// Human-readable detail. Never contains card data or partner body text.
    var message: String { get }
    /// The error this one wraps, when it wraps one.
    var underlying: (any Error)? { get }
}

public extension PurseError {
    var underlying: (any Error)? { nil }

    /// The shared error-codes documentation anchor for ``code``.
    var documentationLink: String { code.documentationLink }

    var description: String { "[\(code.rawValue)] \(message)" }
}

/// Mirrors web's `SESSION_MALFORMED` — anything wrong with a session payload itself, as opposed to
/// a network/API failure (``PaymentAPIError``).
public enum PurseSessionError: PurseError {
    case sessionMalformed(String)

    public var code: PurseErrorCode { .sessionMalformed }

    public var message: String {
        switch self {
        case let .sessionMalformed(detail): detail
        }
    }
}
