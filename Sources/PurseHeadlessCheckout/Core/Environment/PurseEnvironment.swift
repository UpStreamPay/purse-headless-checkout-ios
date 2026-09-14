// Web: packages/sdk/src/types.ts (`Target`) and the per-environment API roots
// Same: same targets and roots.
// Differs: a release build can lock the environment and ignore the session's `api_url`.

import Foundation

/// Payment API environment tier. A release build should pass a locked ``PurseEnvironment`` when
/// creating the checkout rather than trusting whatever a session declares.
public enum PurseEnvironment: String, Sendable, CaseIterable {
    case development
    case test
    case sandbox
    case production

    /// The value as it appears on the wire.
    public var wireValue: String { rawValue }

    public var paymentAPIRoot: String {
        switch self {
        case .development: "https://api.purse-dev.com/payment/v1"
        case .test: "https://api.purse-test.com/payment/v1"
        case .sandbox: "https://api.purse-sandbox.com/payment/v1"
        case .production: "https://api.purse-live.com/payment/v1"
        }
    }

    /// Host root shared by every non-payment API of this tier.
    private var host: String {
        String(paymentAPIRoot.dropLast("/payment/v1".count))
    }

    /// The unversioned `/datetime` root — web's `DATETIME_API_ROOTS`.
    public var datetimeAPIRoot: String { host + "/datetime" }

    /// The monitoring/analytics ingestion root — web's `MONITORING_API_ROOTS`.
    public var monitoringAPIRoot: String { host + "/widget/headless_checkout" }

    /// The Wallet API v2 root — web's `WALLET_API_ROOTS`.
    public var walletAPIRoot: String { host + "/wallet/v2" }

    /// Returns `nil` for a missing or unrecognized value — callers decide whether that is fatal.
    public static func fromWire(_ value: String?) -> PurseEnvironment? {
        guard let value else { return nil }
        return PurseEnvironment(rawValue: value)
    }
}
