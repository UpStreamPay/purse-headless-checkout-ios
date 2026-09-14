// Web: `merchant_specifics.integration_mode`
// Same: `redirection` / `popup`.
// Differs: nothing.

import Foundation

/// `settings.merchant_specifics.integration_mode`.
public enum IntegrationMode: String, Sendable, CaseIterable {
    case popup
    case redirection

    public var wireValue: String { rawValue }

    public static func fromWire(_ value: String?) -> IntegrationMode? {
        guard let value else { return nil }
        return IntegrationMode(rawValue: value)
    }
}
