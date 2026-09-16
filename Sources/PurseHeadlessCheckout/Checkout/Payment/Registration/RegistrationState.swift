// Web: packages/headless-checkout `registration` stores
// Same: registered + optional name.
// Differs: nothing.

import Foundation

/// Whether a method's fresh card should be saved (registered) at `/validate`, and under which label
/// — web's `RegistrationState` store. Defaults come from the method's resolved ``SaveTokenMode``
/// (`.always`/`.prefer` start registered).
public struct RegistrationState: Sendable, Equatable {
    public let registered: Bool
    public let name: String?

    public init(registered: Bool, name: String? = nil) {
        self.registered = registered
        self.name = name
    }
}
