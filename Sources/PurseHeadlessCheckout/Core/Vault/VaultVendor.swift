// Web: packages/sdk/src/types.ts (`VaultVendors`)
// Same: purse / pci_proxy / none.
// Differs: nothing.

import Foundation

/// Who hosts card data capture for a `creditcard` method.
public enum VaultVendor: String, Sendable, CaseIterable {
    /// Purse's own Vault (the Secure Fields iOS SDK) — the only vendor this SDK targets.
    case purse
    /// PSP-hosted fields — out of scope.
    case pciProxy = "pci_proxy"
    /// No vault — secondary methods like Illicado.
    case none
    case unknown = ""

    public var wireValue: String { rawValue }

    public static func fromWire(_ value: String?) -> VaultVendor {
        guard let value, let vendor = VaultVendor(rawValue: value) else { return .unknown }
        return vendor
    }
}
