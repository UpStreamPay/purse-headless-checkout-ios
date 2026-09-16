// Web: packages/sdk/src/API/types.ts (`StatusStates`)
// Same: the five states the Payment API puts in `global_status`.
// Differs: an `unknown` catch-all, so a new server value never crashes a merchant's switch.

import Foundation

/// The Payment API's `global_status` of a `/validate` answer — web's `StatusState`.
public enum PaymentStatus: String, Sendable, CaseIterable {
    /// The payment is authorized (or captured): show the shopper a success.
    case success = "SUCCESS"
    /// The payment was refused.
    case failed = "FAILED"
    /// The API could not process the request.
    case error = "ERROR"
    /// The outcome is not known yet; confirm against the session.
    case uncertain = "UNCERTAIN"
    /// The payment waits on a later step (an asynchronous partner).
    case waiting = "WAITING"
    /// A value this SDK version does not know; the raw string stays on
    /// ``ValidationResult/globalStatus``.
    case unknown = ""

    public var wireValue: String { rawValue }

    public static func fromWire(_ value: String) -> PaymentStatus {
        let upper = value.uppercased()
        return allCases.first { $0 != .unknown && $0.rawValue == upper } ?? .unknown
    }
}
