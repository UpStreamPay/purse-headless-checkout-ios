// Web: packages/partner-ui/src/plugins/index.ts (`getPlugin`) + `partners/partner_plugins.ts`
// Same: resolution order vault → template → integration_mode=redirection → (partner, method) → method.
// Differs: registration is explicit. Android discovers optional artifacts with `ServiceLoader`; Swift has no equivalent and no lazy class loading, so a merchant calls `install(_:)` for each partner product they link.

import Foundation

/// What a plugin builder receives.
public struct PluginBuilderData: Sendable {
    public let partner: Partner
    public let method: PaymentMethod
}

/// Plugins are factory closures, as on web.
public typealias PluginBuilder = @Sendable (PluginBuilderData) -> any PartnerUIPlugin

/// A partner product's registration entry point. Android finds these on the classpath through
/// `ServiceLoader`; iOS cannot, so each optional product exposes one and the merchant installs it
/// at start-up:.
public protocol PartnerModule: Sendable {
    /// A stable identity, so installing the same module twice is a no-op.
    var id: String { get }
    /// Main-actor isolated because the registry is: registration mutates checkout-facing state.
    @MainActor func register(into registry: PluginRegistry)
}

/// Resolves the plugin for a `(partner, method)` of a session.
@MainActor
public final class PluginRegistry {

    public static let shared = PluginRegistry()

    private var vaultPlugins: [VaultVendor: PluginBuilder] = [:]
    private var genericPlugins: [String: PluginBuilder] = [:]
    private var partnerPlugins: [MethodKey: PluginBuilder] = [:]
    private var methodFallbacks: [PaymentMethod: PluginBuilder] = [:]
    private var installed: [String] = []

    /// The built-in plugins every merchant gets — the Purse-vault card and the generic redirection
    /// template — are installed here, mirroring Android's `PluginRegistry` init block. A caller that
    /// registers the same key afterwards wins, which is what lets a test substitute one.
    public init() {
        install(CardModule())
        install(RedirectionModule())
    }

    /// The ids of the modules currently contributing plugins, in installation order.
    public var modules: [String] { installed }

    /// Add a module's plugins. Installing the same module twice is a no-op.
    public func install(_ module: any PartnerModule) {
        guard !installed.contains(module.id) else { return }
        installed.append(module.id)
        module.register(into: self)
    }

    /// Exact `(partner, method)`; last registration wins.
    public func register(partner: Partner, method: PaymentMethod, builder: @escaping PluginBuilder) {
        partnerPlugins[MethodKey(partner: partner, method: method)] = builder
    }

    /// A template plugin keyed on `configurations.template`, serving any pair labelled with it.
    public func registerGeneric(template: String, builder: @escaping PluginBuilder) {
        genericPlugins[template] = builder
    }

    /// A fallback for a method whatever the partner.
    public func registerFallback(method: PaymentMethod, builder: @escaping PluginBuilder) {
        methodFallbacks[method] = builder
    }

    /// A card plugin keyed on `configurations.vault.vendor`.
    public func registerVault(vendor: VaultVendor, builder: @escaping PluginBuilder) {
        vaultPlugins[vendor] = builder
    }

    /// Resolution order, identical to web and Android:
    public func plugin(
        partner: Partner,
        method: PaymentMethod,
        session: LegacyPaymentSession
    ) -> (any PartnerUIPlugin)? {
        guard let configuration = session.protocols[partner]?[method]?.configurations else { return nil }

        var builder: PluginBuilder?
        if let vendor = configuration.vault?.vendor, vendor != VaultVendor.none {
            builder = vaultPlugins[vendor]
        }
        if builder == nil, let template = configuration.template {
            builder = genericPlugins[template]
        }
        if builder == nil, configuration.settings.integrationMode == .redirection {
            builder = genericPlugins[RedirectionPlugin.template]
        }
        if builder == nil {
            builder = partnerPlugins[MethodKey(partner: partner, method: method)]
        }
        if builder == nil {
            builder = methodFallbacks[method]
        }

        return builder?(PluginBuilderData(partner: partner, method: method))
    }

    /// Test-only: forget every registration.
    public func reset() {
        vaultPlugins.removeAll()
        genericPlugins.removeAll()
        partnerPlugins.removeAll()
        methodFallbacks.removeAll()
        installed.removeAll()
    }
}
