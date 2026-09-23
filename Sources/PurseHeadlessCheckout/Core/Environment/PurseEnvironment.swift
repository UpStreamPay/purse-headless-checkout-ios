// Web: packages/sdk/src/types.ts (`Target`) and the per-environment API roots
// Same: same targets and roots.
// Differs: a release build can lock the environment and ignore the session's `api_url`; `.test`/`.development` are refused at runtime in a release-signed app, as Secure Fields iOS does for its `.test` (Android headless not aligned yet).

import Foundation

/// Payment API environment tier. A release build should pass a locked ``PurseEnvironment`` when
/// creating the checkout rather than trusting whatever a session declares.
public enum PurseEnvironment: String, Sendable, CaseIterable {
    case development
    case test
    case sandbox
    case production

    public var wireValue: String { rawValue }

    public var paymentAPIRoot: String {
        switch self {
        case .development: "https://api.purse-dev.com/payment/v1"
        case .test: "https://api.purse-test.com/payment/v1"
        case .sandbox: "https://api.purse-sandbox.com/payment/v1"
        case .production: "https://api.purse-live.com/payment/v1"
        }
    }

    private var host: String {
        String(paymentAPIRoot.dropLast("/payment/v1".count))
    }

    /// Web's `DATETIME_API_ROOTS`.
    public var datetimeAPIRoot: String { host + "/datetime" }

    /// Web's `MONITORING_API_ROOTS`.
    public var monitoringAPIRoot: String { host + "/widget/headless_checkout" }

    /// Web's `WALLET_API_ROOTS`.
    public var walletAPIRoot: String { host + "/wallet/v2" }

    /// The tier actually used: `.test` and `.development` are internal, and fall back to
    /// `.production` unless the host app is a development build. Runtime, not `#if DEBUG`: a
    /// binary release is compiled once, in Release, for every merchant.
    static func resolve(_ requested: PurseEnvironment, isDebugHost: Bool) -> PurseEnvironment {
        guard requested == .test || requested == .development, !isDebugHost else { return requested }
        NSLog("PurseHeadlessCheckout: PurseEnvironment.%@ is not allowed in a release-signed app — falling back to production", requested.rawValue)
        return .production
    }

    /// The simulator, or a binary whose provisioning profile carries `get-task-allow` (Xcode-run,
    /// development and ad-hoc builds). Ported from Secure Fields' `VaultEnvironment.isDebugHost`.
    static var isDebugHost: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              // The profile is CMS-signed; the embedded plist is plain text inside it.
              let text = String(data: data, encoding: .isoLatin1) else {
            return false
        }
        return text.range(of: "<key>get-task-allow</key>\\s*<true/>", options: .regularExpression) != nil
        #endif
    }

    /// `nil` for a missing or unrecognized value — callers decide whether that is fatal.
    public static func fromWire(_ value: String?) -> PurseEnvironment? {
        guard let value else { return nil }
        return PurseEnvironment(rawValue: value)
    }
}
