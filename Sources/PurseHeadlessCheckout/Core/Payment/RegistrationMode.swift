// Web: packages/model registration settings
// Same: same values.
// Differs: nothing.

import Foundation

/// `settings.registration_mode`.
public enum RegistrationMode: String, Sendable, CaseIterable {
    case onSession = "ON_SESSION"
    case offSession = "OFF_SESSION"
    case unknown = ""

    public var wireValue: String { rawValue }

    public static func fromWire(_ value: String?) -> RegistrationMode {
        guard let value, let mode = RegistrationMode(rawValue: value) else { return .unknown }
        return mode
    }
}
