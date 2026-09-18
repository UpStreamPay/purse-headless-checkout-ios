// Web: packages/headless-checkout payment-element events.
// Same: one terminal signal per payment attempt.
// Differs: not `Sendable` — `PurseError.underlying` is an arbitrary vendor error. Everything here is `@MainActor`.

import Foundation

/// How a payment attempt ended. The shopper may retry after ``canceled`` or ``failed(_:)``, never
/// after ``completed(_:)``.
public enum PaymentOutcome {

    /// `/validate` answered without a redirect.
    case completed(ValidationResult)

    /// The shopper came back from a redirect. **Not** an outcome: the final redirect is built
    /// server-side and can land on a URL this client cannot read. Confirm against the session.
    case returnedFromRedirect(url: URL?)

    case canceled

    /// No payment was made, and nothing was charged — except a `validateFailed` wrapping a
    /// `PaymentAPIError` with `outcomeUnknown`, which left the device unanswered. Confirm that one.
    case failed(any PurseError)

    public var status: PaymentStatus? {
        if case let .completed(result) = self { return result.status }
        return nil
    }

    /// A redirect return is not a success.
    public var isSuccess: Bool {
        if case let .completed(result) = self { return result.isSuccess }
        return false
    }
}
