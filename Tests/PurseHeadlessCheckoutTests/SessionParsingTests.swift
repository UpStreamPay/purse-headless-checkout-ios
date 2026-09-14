import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// The per-method configuration parsing — the part that decides what a method is allowed to do.
struct SessionParsingTests {

    private func configuration(
        settings: [String: Any] = [:],
        labels: [String] = []
    ) throws -> MethodConfiguration {
        let session = TestSessions.paymentSession(
            protocols: TestSessions.cardProtocol(settings: settings, labels: labels)
        )
        let params = try SessionCodec.decode(TestSessions.widgetData(paymentSession: session))
        return try #require(params.paymentSession.protocols[.purse]?[.creditCard]?.configurations)
    }

    // MARK: save_token resolution — web's resolveSaveTokenMode

    @Test func saveTokenAbsentMeansNever() throws {
        #expect(try configuration().settings.resolvedSaveTokenMode == .never)
    }

    /// An explicit `false` beats an explicit mode — the one ordering rule that is easy to get wrong.
    @Test func explicitFalseOverridesAnExplicitMode() throws {
        let settings: [String: Any] = ["save_token": false, "save_token_mode": "ALWAYS"]
        #expect(try configuration(settings: settings).settings.resolvedSaveTokenMode == .never)
    }

    @Test func explicitModeWinsOverSaveTokenTrue() throws {
        let settings: [String: Any] = ["save_token": true, "save_token_mode": "PREFER"]
        #expect(try configuration(settings: settings).settings.resolvedSaveTokenMode == .prefer)
    }

    @Test func saveTokenTrueAloneMeansPreferNo() throws {
        #expect(try configuration(settings: ["save_token": true]).settings.resolvedSaveTokenMode == .preferNo)
    }

    @Test func unknownModeFallsBackToNever() throws {
        let settings: [String: Any] = ["save_token_mode": "WHENEVER"]
        #expect(try configuration(settings: settings).settings.resolvedSaveTokenMode == .never)
    }

    @Test(arguments: [
        (SaveTokenMode.always, true, false),
        (.prefer, true, true),
        (.preferNo, false, true),
        (.never, false, false),
    ])
    func saveTokenModeDefaults(_ mode: SaveTokenMode, _ registeredByDefault: Bool, _ canBeRegistered: Bool) {
        #expect(mode.registeredByDefault == registeredByDefault)
        #expect(mode.canBeRegistered == canBeRegistered)
    }

    // MARK: secondary

    /// A method is secondary by its `labels`, not by its template or partner.
    @Test func secondaryIsDecidedByTheLabel() throws {
        #expect(try configuration(labels: ["secondary"]).isSecondary)
        #expect(try !configuration(labels: ["whatever"]).isSecondary)
        #expect(try !configuration().isSecondary)
    }

    // MARK: amounts and limits

    @Test func parsesAmountLimitsAsExactDecimals() throws {
        let settings: [String: Any] = [
            "payment_min_amount": 0.01,
            "payment_max_amount": 1000.00,
            "usage_per_session_limit": 3,
        ]
        let parsed = try configuration(settings: settings).settings

        #expect(parsed.paymentMinAmount == Decimal(string: "0.01"))
        #expect(parsed.paymentMaxAmount == Decimal(string: "1000.00"))
        #expect(parsed.usagePerSessionLimit == 3)
    }

    // MARK: merchant_specifics

    @Test func readsMerchantSpecifics() throws {
        let settings: [String: Any] = [
            "network_token": true,
            "merchant_specifics": [
                "integration_mode": "redirection",
                "client_id": "client-abc",
                "pay_token_no_cvv": true,
            ],
        ]
        let parsed = try configuration(settings: settings).settings

        #expect(parsed.integrationMode == .redirection)
        #expect(parsed.merchantClientId == "client-abc")
        #expect(parsed.payTokenNoCVV)
        #expect(parsed.networkToken)
    }

    @Test func defaultsMerchantSpecificsWhenAbsent() throws {
        let parsed = try configuration().settings
        #expect(parsed.integrationMode == nil)
        #expect(!parsed.payTokenNoCVV)
        #expect(!parsed.networkToken)
        #expect(parsed.registrationMode == .unknown)
    }

    // MARK: integrated tokens

    @Test func parsesIntegratedTokens() throws {
        let token: [String: Any] = [
            "id": "tok-1",
            "value": "vault-token-1",
            "uniqueness_token": "uniq-1",
            "favorite": true,
            "source": "SHARED_WALLET",
            "network_token": ["available": true],
            "description": [
                "brand_name": "VISA",
                "masked_pan": "411111******1111",
                "holder_name": "A Shopper",
            ],
        ]
        let session = TestSessions.paymentSession(
            protocols: TestSessions.cardProtocol(integratedTokens: [token])
        )
        let params = try SessionCodec.decode(TestSessions.widgetData(paymentSession: session))
        let parsed = try #require(params.paymentSession.protocols[.purse]?[.creditCard]?.integratedTokens.first)

        #expect(parsed.id == "tok-1")
        #expect(parsed.value == "vault-token-1")
        #expect(parsed.favorite)
        #expect(parsed.source == .sharedWallet)
        #expect(parsed.networkTokenAvailable)
        #expect(parsed.maskedPAN == "411111******1111")
        #expect(parsed.brandName == "VISA")
    }

    /// A token with no id or no value cannot be paid with; dropping it must not fail the session.
    @Test(arguments: ["id", "value"])
    func skipsUnusableIntegratedTokensWithoutFailingTheSession(_ missing: String) throws {
        var token: [String: Any] = ["id": "tok-1", "value": "vault-token-1"]
        token.removeValue(forKey: missing)
        let session = TestSessions.paymentSession(
            protocols: TestSessions.cardProtocol(integratedTokens: [token])
        )
        let params = try SessionCodec.decode(TestSessions.widgetData(paymentSession: session))

        #expect(params.paymentSession.protocols[.purse]?[.creditCard]?.integratedTokens.isEmpty == true)
    }

    @Test func defaultsTokenSourceToMerchant() {
        #expect(TokenSource.fromWire(nil) == .merchant)
        #expect(TokenSource.fromWire("NONSENSE") == .merchant)
        #expect(TokenSource.fromWire("SHARED_WALLET") == .sharedWallet)
    }
}
