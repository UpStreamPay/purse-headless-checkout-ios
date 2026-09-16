// Web: packages/model `vault.vendor_front_data`
// Same: purse tenant id, pci-proxy merchant id.
// Differs: nothing.

import Foundation

/// The session-level `vault` field — distinct from the per-method ``VaultInfo`` inside
/// ``MethodConfiguration``. This is where the Secure Fields SDK's `tenantId` comes from.
public struct SessionVault: Sendable, Equatable {
    public let vendorFrontData: VendorFrontData

    public init(vendorFrontData: VendorFrontData) {
        self.vendorFrontData = vendorFrontData
    }
}

public struct VendorFrontData: Sendable, Equatable {
    public let purse: PurseVaultInfo?
    public let pciProxy: PCIProxyVaultInfo?

    public init(purse: PurseVaultInfo?, pciProxy: PCIProxyVaultInfo?) {
        self.purse = purse
        self.pciProxy = pciProxy
    }
}

public struct PurseVaultInfo: Sendable, Equatable {
    public let tenantId: String

    public init(tenantId: String) {
        self.tenantId = tenantId
    }
}

public struct PCIProxyVaultInfo: Sendable, Equatable {
    public let merchantId: String

    public init(merchantId: String) {
        self.merchantId = merchantId
    }
}
