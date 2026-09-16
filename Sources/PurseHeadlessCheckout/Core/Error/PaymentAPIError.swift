// Web: packages/sdk/src/API (fetch error shape)
// Same: status + API error code; a terminal session answer is recognisable.
// Differs: one error type instead of per-status classes; shares the SDK's PurseError root (code API_ERROR).

import Foundation

/// Raised when a Payment API call fails at the transport level, returns a non-2xx/3xx status, or
/// produces a response the caller cannot use.
public struct PaymentAPIError: PurseError {
    public let message: String
    public let underlying: (any Error)?
    /// HTTP status of the failing response; `nil` when the request never got one (network).
    public let status: Int?
    /// The `error` code from the API's JSON error body, when one was parseable.
    public let errorCode: String?
    /// The request path that failed, e.g. `/init`.
    public let path: String?
    /// Whether the request was actually put on the wire. `false` only for a failure raised *before*
    /// any byte was sent — an unusable URL, a body that could not be encoded.
    public let requestSent: Bool

    public var code: PurseErrorCode { .apiError }

    public init(
        _ message: String,
        underlying: (any Error)? = nil,
        status: Int? = nil,
        errorCode: String? = nil,
        path: String? = nil,
        requestSent: Bool = true
    ) {
        self.message = message
        self.underlying = underlying
        self.status = status
        self.errorCode = errorCode
        self.path = path
        self.requestSent = requestSent
    }

    /// Whether the request may have reached the server even though no answer came back — a
    /// transport failure with no ``status``.
    public var outcomeUnknown: Bool { status == nil && requestSent }

    /// The session itself is spent — already submitted, expired, or gone — so every further call is
    /// pointless: web's `SESSION_TERMINAL_ERRORS`. Callers should surface a terminated session state.
    public var isSessionTerminal: Bool {
        guard let errorCode else { return false }
        return Self.sessionTerminalErrorCodes.contains(errorCode)
    }

    /// Whether retrying the exact same call could help. A 4xx is a definitive backend decision
    /// (submitted, expired, not found, malformed, 429 step budget spent) — only a 5xx (outage) or a
    /// transport failure with no status at all is worth retrying.
    public var isRetryable: Bool {
        // A malformed URL or an unencodable body is deterministic: the same call fails the same way
        // every time, so retrying it only delays the error the caller already has.
        guard requestSent else { return false }
        guard let status else { return true }
        return status >= 500
    }

    /// Body `error` values that mean the session is finished for good.
    public static let sessionTerminalErrorCodes: Set<String> = [
        "SESSION_ALREADY_SUBMITTED_ERROR", "SESSION_EXPIRED", "NOT_FOUND",
    ]
}
