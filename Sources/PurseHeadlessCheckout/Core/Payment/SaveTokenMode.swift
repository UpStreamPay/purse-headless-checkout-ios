// Web: packages/model `save_token_mode`
// Same: ALWAYS / NEVER / PREFER / PREFER_NO and their defaults.
// Differs: nothing.

import Foundation

/// The effective save-token (card registration) policy for a method. `always`/`never` are backend-
/// enforced; only `prefer`/`preferNo` give the shopper a choice (a checkbox, checked respectively
/// unchecked by default).
public enum SaveTokenMode: String, Sendable, CaseIterable {
    case always = "ALWAYS"
    case prefer = "PREFER"
    case preferNo = "PREFER_NO"
    case never = "NEVER"

    /// Whether the shopper can choose — web's `canBeRegisteredFromMode`.
    public var canBeRegistered: Bool { self == .prefer || self == .preferNo }

    /// Whether registration starts on — web defaults `registered` for `ALWAYS`/`PREFER`.
    public var registeredByDefault: Bool { self == .always || self == .prefer }

    public static func fromWire(_ value: String?) -> SaveTokenMode? {
        guard let value else { return nil }
        return SaveTokenMode(rawValue: value)
    }
}

public extension MethodSettings {
    /// Resolves the effective mode from `settings.save_token` / `save_token_mode` — the exact port
    /// of web's `resolveSaveTokenMode` (`item-factory/primaries.ts`): - an explicit `save_token:
    /// false` disables saving unconditionally; - otherwise an explicit `save_token_mode` wins; -
    var resolvedSaveTokenMode: SaveTokenMode {
        if saveToken == false { return .never }
        if let saveTokenMode { return SaveTokenMode.fromWire(saveTokenMode) ?? .never }
        if saveToken == true { return .preferNo }
        return .never
    }
}
