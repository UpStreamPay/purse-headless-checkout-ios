// Web: packages/sdk/src/types.ts (`Target`) and the per-environment API roots
// Same: same targets and roots.
// Differs: a release build can lock the tier, keeping the session's `api_url` only on that tier's host (web keeps it on any host); `.test`/`.development` are refused at runtime in a release-signed app with ENVIRONMENT_NOT_ALLOWED (Secure Fields iOS falls back on its `.test` instead; Android aligns in SDK-12577).

import Foundation

/// Payment API environment tier. A release build should pass a locked ``PurseEnvironment`` when
/// creating the checkout rather than trusting whatever a session declares. The lock pins the tier's
/// host, not the API version: see ``lockedPaymentAPIRoot(_:)``.
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

    /// The Payment API root a build locked to this tier uses for a session declaring `apiURL`: the
    /// session's own root when it is `https` on this tier's host with no port or user info (an
    /// orchestration session declares `…/payment/v2`), otherwise ``paymentAPIRoot``.
    func lockedPaymentAPIRoot(_ apiURL: String) -> String {
        guard let declared = URLComponents(string: apiURL),
              declared.scheme?.lowercased() == "https",
              declared.host?.lowercased() == URLComponents(string: paymentAPIRoot)?.host,
              declared.port == nil,
              declared.user == nil,
              declared.password == nil else {
            return paymentAPIRoot
        }
        return apiURL
    }

    /// `requested`, unless `.test` / `.development` in a release-signed app: refused, not swapped
    /// for production. Runtime, not `#if DEBUG`: one Release binary ships to every merchant.
    static func resolve(_ requested: PurseEnvironment, isDebugHost: Bool) throws -> PurseEnvironment {
        guard requested == .test || requested == .development, !isDebugHost else { return requested }
        throw PurseSessionError.environmentNotAllowed(requested)
    }

    /// The tier whose Payment API host `apiURL` names, if it names one.
    static func of(apiURL: String) -> PurseEnvironment? {
        guard let host = URLComponents(string: apiURL)?.host?.lowercased() else { return nil }
        return allCases.first { URLComponents(string: $0.paymentAPIRoot)?.host == host }
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
