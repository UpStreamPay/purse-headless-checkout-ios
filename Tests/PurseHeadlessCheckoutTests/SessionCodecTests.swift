import Foundation
import Testing
@testable import PurseHeadlessCheckout

struct SessionCodecTests {

    // MARK: Happy path

    @Test func decodesTheEnvelope() throws {
        let params = try SessionCodec.decode(TestSessions.widgetData())

        #expect(params.apiKey == "test-key")
        #expect(params.environment == .sandbox)
        #expect(params.entityId == "entity-1")
        #expect(params.paymentSession.id == "session-1")
        #expect(params.paymentSession.currencyCode == "EUR")
        #expect(params.walletSession == nil)
    }

    @Test func decodesAmountWithoutBinaryFloatingPointDrift() throws {
        // The reason `JSONValue.number` keeps the literal text: 42.50 through a Double is
        // 42.499999999999996, and an amount that drifts is an amount that splits wrong.
        let params = try SessionCodec.decode(TestSessions.widgetData())
        #expect(params.paymentSession.amount == Decimal(string: "42.50"))
    }

    @Test func decodesTheVaultTenantId() throws {
        let params = try SessionCodec.decode(TestSessions.widgetData())
        #expect(params.paymentSession.vault?.vendorFrontData.purse?.tenantId == "tenant-1")
        #expect(params.paymentSession.vault?.vendorFrontData.pciProxy == nil)
    }

    @Test func decodesProtocolsWithTypedKeys() throws {
        let params = try SessionCodec.decode(TestSessions.widgetData())
        let entry = params.paymentSession.protocols[.purse]?[.creditCard]

        #expect(entry != nil)
        #expect(entry?.configurations.stable == true)
        #expect(entry?.configurations.vault?.vendor == .purse)
        #expect(entry?.configurations.vault?.supportedBrands == [.visa, .mastercard])
    }

    @Test func decodesWalletSession() throws {
        let widgetData = TestSessions.widgetData(walletSession: [
            "session_id": "wallet-1",
            "owner_reference": "owner-1",
            "merchant": "merchant-1",
        ])
        let params = try SessionCodec.decode(widgetData)

        #expect(params.walletSession?.sessionId == "wallet-1")
        #expect(params.walletSession?.merchant == "merchant-1")
    }

    /// A wallet session that grants nothing is dropped rather than half-built.
    @Test func dropsWalletSessionMissingItsIdentifiers() throws {
        let widgetData = TestSessions.widgetData(walletSession: ["merchant": "merchant-1"])
        #expect(try SessionCodec.decode(widgetData).walletSession == nil)
    }

    // MARK: Malformed input

    @Test func rejectsNonBase64() {
        #expect(throws: PurseSessionError.self) {
            try SessionCodec.decode("not base64 at all !!!")
        }
    }

    @Test func rejectsNonJSON() {
        #expect(throws: PurseSessionError.self) {
            try SessionCodec.decode(TestSessions.base64("definitely not json"))
        }
    }

    @Test func rejectsMissingPaymentSession() {
        let widgetData = TestSessions.encode(["environment": "sandbox"])
        #expect(throws: PurseSessionError.self) {
            try SessionCodec.decode(widgetData)
        }
    }

    @Test func rejectsUnknownEnvironment() {
        #expect(throws: PurseSessionError.self) {
            try SessionCodec.decode(TestSessions.widgetData(environment: "staging"))
        }
    }

    /// The only two structural checks the parser makes — deliberately matching web's
    /// `checkSessionFormat`, so an unknown method never fails the decode.
    @Test(arguments: ["id", "expiration_date"])
    func rejectsSessionMissing(_ field: String) {
        var session = TestSessions.paymentSession()
        session.removeValue(forKey: field)
        #expect(throws: PurseSessionError.self) {
            try SessionCodec.decode(TestSessions.widgetData(paymentSession: session))
        }
    }

    @Test func rejectsUnparseableExpirationDate() {
        let session = TestSessions.paymentSession(expirationDate: "the day after tomorrow")
        #expect(throws: PurseSessionError.self) {
            try SessionCodec.decode(TestSessions.widgetData(paymentSession: session))
        }
    }

    @Test(arguments: ["2099-01-01T00:00:00Z", "2099-01-01T00:00:00.123Z"])
    func acceptsExpirationDateWithAndWithoutFractionalSeconds(_ value: String) throws {
        let session = TestSessions.paymentSession(expirationDate: value)
        let params = try SessionCodec.decode(TestSessions.widgetData(paymentSession: session))
        #expect(params.paymentSession.expirationDate > Date())
    }

    /// Android's JDK basic decoder accepts a missing `=` pad; `Data(base64Encoded:)` rejects it
    /// outright. A backend that strips padding would otherwise work on Android and fail on every
    /// iOS device — one blob, two verdicts.
    @Test func decodesBase64WhosePaddingWasStripped() throws {
        // Whether a blob needs padding depends on its byte length, so pick an id that produces one
        // that does rather than assuming the default fixture happens to.
        let padded = try #require(
            ["session-1", "session-12", "session-123", "session-1234"]
                .map { TestSessions.widgetData(paymentSession: TestSessions.paymentSession(id: $0)) }
                .first { $0.hasSuffix("=") }
        )
        let unpadded = padded.replacingOccurrences(of: "=", with: "")

        let params = try SessionCodec.decode(unpadded)
        #expect(params.apiKey == "test-key")
    }

    /// An unknown partner or method must survive the decode, or a backend rollout breaks every
    /// shipped app.
    @Test func keepsUnknownPartnersAndMethods() throws {
        let protocols = ["newpsp": ["newmethod": ["configurations": ["stable": true]]]]
        let session = TestSessions.paymentSession(protocols: protocols)
        let params = try SessionCodec.decode(TestSessions.widgetData(paymentSession: session))

        let entry = params.paymentSession.protocols[.other("newpsp")]?[.other("newmethod")]
        #expect(entry?.configurations.stable == true)
    }
}
