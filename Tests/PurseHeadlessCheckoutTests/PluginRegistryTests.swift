import Foundation
import Testing
@testable import PurseHeadlessCheckout

@MainActor
struct PluginRegistryTests {

    private struct StubPlugin: PartnerUIPlugin {
        let partner: Partner
        let method: PaymentMethod
        let tag: String
        func preValidation(_ context: PartnerUIContext) async throws -> ValidateItemPayload {
            ItemPayload(partner: partner, method: method, amount: context.amount)
        }
    }

    private func registry(configuring: (PluginRegistry) -> Void = { _ in }) -> PluginRegistry {
        let registry = PluginRegistry()
        registry.install(RedirectionModule())
        configuring(registry)
        return registry
    }

    private func session(
        vaultVendor: String? = nil,
        template: String? = nil,
        integrationMode: String? = nil,
        partner: String = "purse",
        method: String = "creditcard"
    ) throws -> LegacyPaymentSession {
        var configurations: [String: Any] = ["stable": true, "labels": [], "settings": [:]]
        if let vaultVendor { configurations["vault"] = ["vendor": vaultVendor] }
        if let template { configurations["template"] = template }
        if let integrationMode {
            configurations["settings"] = ["merchant_specifics": ["integration_mode": integrationMode]]
        }
        let protocols = [partner: [method: ["configurations": configurations]]]
        let widgetData = TestSessions.widgetData(
            paymentSession: TestSessions.paymentSession(protocols: protocols)
        )
        return try SessionCodec.decode(widgetData).paymentSession
    }

    private func tag(_ plugin: (any PartnerUIPlugin)?) -> String? {
        (plugin as? StubPlugin)?.tag
    }

    // MARK: Resolution order

    /// A vault vendor wins over everything else — a card is captured by its vault's plugin.
    @Test func vaultVendorWinsFirst() throws {
        let registry = registry {
            $0.registerVault(vendor: .purse) { StubPlugin(partner: $0.partner, method: $0.method, tag: "vault") }
            $0.registerGeneric(template: "custom") { StubPlugin(partner: $0.partner, method: $0.method, tag: "generic") }
            $0.register(partner: .purse, method: .creditCard) { StubPlugin(partner: $0.partner, method: $0.method, tag: "exact") }
        }
        let session = try session(vaultVendor: "purse", template: "custom")

        #expect(tag(registry.plugin(partner: .purse, method: .creditCard, session: session)) == "vault")
    }

    @Test func aTemplateWinsOverTheExactPair() throws {
        let registry = registry {
            $0.registerGeneric(template: "custom") { StubPlugin(partner: $0.partner, method: $0.method, tag: "generic") }
            $0.register(partner: .purse, method: .creditCard) { StubPlugin(partner: $0.partner, method: $0.method, tag: "exact") }
        }
        let session = try session(template: "custom")

        #expect(tag(registry.plugin(partner: .purse, method: .creditCard, session: session)) == "generic")
    }

    /// `integration_mode: redirection` routes to the generic redirection template even with no
    /// `template` field — web checks this before its own partner table too.
    @Test func redirectionIntegrationModeRoutesToTheRedirectionTemplate() throws {
        let session = try session(integrationMode: "redirection", partner: "aci", method: "creditcard")
        let plugin = registry().plugin(partner: .aci, method: .creditCard, session: session)

        #expect(plugin is RedirectionPlugin)
    }

    @Test func theExactPairWinsOverTheMethodFallback() throws {
        let registry = registry {
            $0.register(partner: .purse, method: .creditCard) { StubPlugin(partner: $0.partner, method: $0.method, tag: "exact") }
            $0.registerFallback(method: .creditCard) { StubPlugin(partner: $0.partner, method: $0.method, tag: "fallback") }
        }
        #expect(tag(registry.plugin(partner: .purse, method: .creditCard, session: try session())) == "exact")
    }

    @Test func theMethodFallbackIsLast() throws {
        let registry = registry {
            $0.registerFallback(method: .creditCard) { StubPlugin(partner: $0.partner, method: $0.method, tag: "fallback") }
        }
        #expect(tag(registry.plugin(partner: .purse, method: .creditCard, session: try session())) == "fallback")
    }

    /// A vault vendor of `none` is not a vault — it must not claim the item.
    @Test func aNoneVaultVendorDoesNotClaimTheItem() throws {
        let registry = registry {
            $0.registerVault(vendor: .none) { StubPlugin(partner: $0.partner, method: $0.method, tag: "vault") }
            $0.registerFallback(method: .creditCard) { StubPlugin(partner: $0.partner, method: $0.method, tag: "fallback") }
        }
        #expect(tag(registry.plugin(partner: .purse, method: .creditCard, session: try session(vaultVendor: "none"))) == "fallback")
    }

    @Test func anUnknownMethodResolvesToNothing() throws {
        #expect(registry().plugin(partner: .paypal, method: .wallet, session: try session()) == nil)
    }

    /// A method the session does not offer resolves to nothing, whatever is registered.
    @Test func aMethodOutsideTheSessionResolvesToNothing() throws {
        let registry = registry {
            $0.registerFallback(method: .wallet) { StubPlugin(partner: $0.partner, method: $0.method, tag: "fallback") }
        }
        #expect(registry.plugin(partner: .paypal, method: .wallet, session: try session()) == nil)
    }

    // MARK: Modules

    @Test func installingTheSameModuleTwiceIsANoOp() {
        let registry = PluginRegistry()
        registry.install(RedirectionModule())
        registry.install(RedirectionModule())

        #expect(registry.modules == ["purse.redirection"])
    }
}
