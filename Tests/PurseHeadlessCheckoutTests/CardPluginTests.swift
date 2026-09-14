import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// The card plugin's payload shapes. The form itself is exercised by the coordinator; this pins
/// what actually reaches `/validate`, which is where a wrong key silently breaks a payment.
@MainActor
@Suite(.serialized)
struct CardPluginTests {

    private func context(
        amount: Decimal = 100,
        collected: [String: JSONValue] = [:],
        token: PayToken? = nil
    ) throws -> PartnerUIContext {
        let params = try SessionCodec.decode(TestSessions.widgetData())
        return PartnerUIContext(
            partner: .purse,
            method: .creditCard,
            session: params.paymentSession,
            amount: amount,
            api: PaymentAPIClient(
                apiKey: "k", apiRoot: "https://api.example/payment/v1",
                entityId: "e", sessionId: "s", session: StubURLProtocol.session()
            ),
            token: token,
            collected: collected
        )
    }

    /// This suite's own host, so it cannot collide with another suite's stub state.
    private static let host = "api.example"

    private func stubInit(_ body: String = #"{"status":{"state":"SUCCESS"},"step_id":7}"#) {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/init", .ok(body), host: Self.host)
    }

    // MARK: Fresh card

    @Test func freshCardCarriesTheVaultTokenAtTopLevel() async throws {
        stubInit()
        let plugin = CardPlugin(partner: .purse)
        let payload = try await plugin.preValidation(context(collected: [
            CardPlugin.Collected.token: "vault-tok-1",
            CardPlugin.Collected.bin: "411111",
            CardPlugin.Collected.network: "VISA",
        ]))

        // `vault_vendor_token_id` is top level, NOT nested under `card` — the Vault reads it there.
        #expect(payload.paymentData["vault_vendor_token_id"]?.stringValue == "vault-tok-1")
        #expect(payload.paymentData["vault_vendor"]?.stringValue == "purse")
        #expect(payload.paymentData["card"]?["bin"]?.stringValue == "411111")
        #expect(payload.paymentData["card"]?["selected_network"]?.stringValue == "VISA")
        #expect(payload.stepId == 7)
    }

    @Test func freshCardWithoutATokenIsRefused() async throws {
        stubInit()
        let plugin = CardPlugin(partner: .purse)

        await #expect(throws: PartnerUIError.self) {
            _ = try await plugin.preValidation(try context())
        }
    }

    /// Omitting absent metadata rather than sending empty strings — the vault rejects blanks.
    @Test func absentCardMetadataIsOmitted() async throws {
        stubInit()
        let plugin = CardPlugin(partner: .purse)
        let payload = try await plugin.preValidation(context(collected: [
            CardPlugin.Collected.token: "vault-tok-1",
        ]))

        #expect(payload.paymentData["card"]?.objectValue?.isEmpty == true)
    }

    // MARK: Saved card

    /// A saved card that pays without a CVV carries its token and no vault tokenization at all.
    @Test func savedCardWithoutCVVNeedsNoVaultToken() async throws {
        stubInit()
        let token = PayToken(value: "tok-saved", expirationDate: "2030-04-30T00:00:00Z",
                             holderName: "A Shopper", selectedNetwork: "VISA", requiresCVV: false)
        let payload = try await CardPlugin(partner: .purse).preValidation(context(token: token))

        #expect(payload.paymentData["token"]?.stringValue == "tok-saved")
        #expect(payload.paymentData["holder"]?.stringValue == "A Shopper")
        #expect(payload.paymentData["card"]?["expiry_date"]?.stringValue == "2030-04-30")
        #expect(payload.paymentData["card"]?["selected_network"]?.stringValue == "VISA")
        #expect(payload.paymentData["vault_vendor_token_id"] == nil)
    }

    /// A saved card that still wants its cryptogram pairs `token` with the CVV-only tokenization —
    /// the same key a fresh card uses, and the Vault pairs the two server-side.
    @Test func savedCardWithCVVPairsTokenAndVaultToken() async throws {
        stubInit()
        let token = PayToken(value: "tok-saved", requiresCVV: true)
        let payload = try await CardPlugin(partner: .purse).preValidation(
            context(collected: [CardPlugin.Collected.token: "cvv-vault-tok"], token: token)
        )

        #expect(payload.paymentData["token"]?.stringValue == "tok-saved")
        #expect(payload.paymentData["vault_vendor_token_id"]?.stringValue == "cvv-vault-tok")
    }

    @Test func savedCardNeedingACVVWithoutOneIsRefused() async throws {
        stubInit()
        let token = PayToken(value: "tok-saved", requiresCVV: true)

        await #expect(throws: PartnerUIError.self) {
            _ = try await CardPlugin(partner: .purse).preValidation(try context(token: token))
        }
    }

    // MARK: validateUI

    @Test func validateUIGatesOnWhatTheFormProduced() async throws {
        let plugin = CardPlugin(partner: .purse)

        #expect(try await !plugin.validateUI(context()))
        #expect(try await plugin.validateUI(context(collected: [CardPlugin.Collected.token: "t"])))
        // A saved card that needs no form is always ready.
        #expect(try await plugin.validateUI(context(token: PayToken(value: "t", requiresCVV: false))))
        // …one that does need a form is not, until it has tokenized.
        #expect(try await !plugin.validateUI(context(token: PayToken(value: "t", requiresCVV: true))))
    }

    // MARK: /init

    /// A refused init must not be mistaken for a usable step id.
    @Test func aRefusedInitThrows() async throws {
        stubInit(#"{"status":{"state":"FAILED","description":"nope"}}"#)

        await #expect(throws: PaymentAPIError.self) {
            _ = try await CardPlugin(partner: .purse).preValidation(
                try context(collected: [CardPlugin.Collected.token: "t"])
            )
        }
    }

    @Test func anInitWithoutAStepIdIsFine() async throws {
        stubInit(#"{"status":{"state":"SUCCESS"}}"#)
        let payload = try await CardPlugin(partner: .purse).preValidation(
            context(collected: [CardPlugin.Collected.token: "t"])
        )
        #expect(payload.stepId == nil)
    }

    // MARK: Mode selection

    @Test func modeFollowsTheToken() {
        #expect(CardCoordinator.Mode.of(nil) == .freshCard)
        #expect(CardCoordinator.Mode.of(PayToken(value: "t", requiresCVV: true)) == .tokenCVV)
        #expect(CardCoordinator.Mode.of(PayToken(value: "t", requiresCVV: false)) == .tokenNoCVV)

        #expect(CardCoordinator.Mode.freshCard.rendersForm)
        #expect(CardCoordinator.Mode.tokenCVV.rendersForm)
        #expect(!CardCoordinator.Mode.tokenNoCVV.rendersForm)
    }

    // MARK: Brand vocabulary

    /// Secure Fields says `AMEX` where the Payment API says `AMERICAN_EXPRESS`. A raw-value cast
    /// would tokenize an Amex under the wrong network.
    @Test func brandMappingCrossesTheVocabularies() {
        #expect(CardBrand.americanExpress.secureFieldsBrand == .amex)
        #expect(CardBrand.fromSecureFields(.amex) == .americanExpress)
        #expect(CardBrand.carteBancaire.secureFieldsBrand == .carteBancaire)
        #expect(CardBrand.oney.secureFieldsBrand == .oney)
    }

    /// Brands the vault has no equivalent for are dropped, not guessed at.
    @Test func brandsSecureFieldsCannotExpressAreDropped() {
        #expect(CardBrand.jcb.secureFieldsBrand == nil)
        #expect(CardBrand.discover.secureFieldsBrand == nil)
        #expect(CardBrand.unionPay.secureFieldsBrand == nil)
        #expect(CardBrand.dinersClub.secureFieldsBrand == nil)
    }

    @Test func environmentsMapToVaultTiers() {
        #expect(PurseEnvironment.production.vaultEnvironment == .production)
        #expect(PurseEnvironment.sandbox.vaultEnvironment == .sandbox)
        // Development has no vault of its own.
        #expect(PurseEnvironment.development.vaultEnvironment == .sandbox)
    }
}
