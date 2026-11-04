// Web: packages/sdk/src/API/types.ts (`StatusStates`)
// Same: the five states the Payment API puts in `global_status`.
// Differs: an `unknown` catch-all, so a new server value never crashes a merchant's switch.

import Foundation

/// The Payment API's `global_status` of a `/validate` answer — web's `StatusState`.
public enum PaymentStatus: String, Sendable, CaseIterable {
    case success = "SUCCESS"
    case failed = "FAILED"
    case error = "ERROR"
    /// Outcome not known yet; confirm from your backend.
    case uncertain = "UNCERTAIN"
    /// Waiting on a later step (an asynchronous partner).
    case waiting = "WAITING"
    /// Unknown to this SDK version; the raw string stays on ``ValidationResult/globalStatus``.
    case unknown = ""

    public var wireValue: String { rawValue }

    public static func fromWire(_ value: String) -> PaymentStatus {
        let upper = value.uppercased()
        return allCases.first { $0 != .unknown && $0.rawValue == upper } ?? .unknown
    }
}
