// Web: packages/sdk/src/API (fetch error shape)
// Same: status + API error code; a terminal session answer is recognisable.
// Differs: one error type instead of per-status classes; shares the SDK's PurseError root (code API_ERROR); the error body (web's `apiErrorDetail`) only in a development build, as `responseBody`.

import Foundation

/// A Payment API call that failed in transport, returned a non-2xx/3xx status, or produced a
/// response the caller cannot use.
public struct PaymentAPIError: PurseError {
    public let message: String
    public let underlying: (any Error)?
    /// `nil` when the request never got a status back (network).
    public let status: Int?
    /// The `error` code from the API's JSON error body, when one was parseable.
    public let errorCode: String?
    public let path: String?
    /// The raw error body, to diagnose a refusal. Development builds only (simulator or a
    /// development-signed app); never in ``message`` or monitoring, as it can quote shopper input.
    public let responseBody: String?
    /// `false` only for a failure raised *before* any byte was sent — an unusable URL, a body that
    /// could not be encoded.
    public let requestSent: Bool

    public var code: PurseErrorCode { .apiError }

    public init(
        _ message: String,
        underlying: (any Error)? = nil,
        status: Int? = nil,
        errorCode: String? = nil,
        path: String? = nil,
        requestSent: Bool = true,
        responseBody: String? = nil
    ) {
        self.message = message
        self.underlying = underlying
        self.status = status
        self.errorCode = errorCode
        self.path = path
        self.requestSent = requestSent
        self.responseBody = responseBody
    }

    /// The request may have reached the server with no answer coming back: the payment may exist.
    /// Never report this to the shopper as a failed payment.
    public var outcomeUnknown: Bool { status == nil && requestSent }

    /// Web's `SESSION_TERMINAL_ERRORS`: the session is spent, so every further call is pointless.
    public var isSessionTerminal: Bool {
        guard let errorCode else { return false }
        return Self.sessionTerminalErrorCodes.contains(errorCode)
    }

    /// A 4xx is a definitive backend decision; only a 5xx or a transport failure with no status is
    /// worth retrying. A request that never went out is deterministic and never retried.
    public var isRetryable: Bool {
        guard requestSent else { return false }
        guard let status else { return true }
        return status >= 500
    }

    public static let sessionTerminalErrorCodes: Set<String> = [
        "SESSION_ALREADY_SUBMITTED_ERROR", "SESSION_EXPIRED", "NOT_FOUND",
    ]
}
