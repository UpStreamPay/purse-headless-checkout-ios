import Foundation
import Testing
@testable import PurseHeadlessCheckout

struct ItemPayloadTests {

    private func encoded(_ payload: ItemPayload) throws -> JSONValue {
        let data = try JSONEncoder().encode(payload.toJSON())
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    @Test func serializesTheWireEnvelope() throws {
        let json = try encoded(
            ItemPayload(partner: .purse, method: .creditCard, amount: Decimal(string: "12.34")!)
        )

        #expect(json["partner"]?.stringValue == "purse")
        #expect(json["method"]?.stringValue == "creditcard")
        #expect(json["amount"]?.decimalValue == Decimal(string: "12.34"))
        #expect(json["step_id"] == nil)
    }

    /// Web's `normalizePaymentData`: a plugin that sets no vault still sends `"none"`.
    @Test func defaultsVaultVendorToNone() throws {
        let json = try encoded(ItemPayload(partner: .purse, method: .creditCard, amount: 10))
        #expect(json["payment_data"]?["vault_vendor"]?.stringValue == "none")
    }

    @Test func keepsAVaultVendorThePluginSet() throws {
        let payload = ItemPayload(
            partner: .purse,
            method: .creditCard,
            amount: 10,
            paymentData: ["vault_vendor": "purse", "token": "tok-1"]
        )
        let json = try encoded(payload)

        #expect(json["payment_data"]?["vault_vendor"]?.stringValue == "purse")
        #expect(json["payment_data"]?["token"]?.stringValue == "tok-1")
    }

    @Test func includesStepIdOnlyWhenSet() throws {
        let payload = ItemPayload(partner: .paypal, method: .wallet, amount: 10, stepId: 2)
        #expect(try encoded(payload)["step_id"]?.intValue == 2)
    }

    @Test func amountSurvivesTheRoundTripExactly() throws {
        let amount = Decimal(string: "0.07")!
        let payload = ItemPayload(partner: .purse, method: .creditCard, amount: amount)
        #expect(try encoded(payload)["amount"]?.decimalValue == amount)
    }
}

struct ValidationResultTests {

    @Test func readsGlobalStatus() {
        let result = ValidationResult.fromJSON(.object(["global_status": "SUCCESS"]))
        #expect(result.status == .success)
        #expect(result.isSuccess)
    }

    @Test func anUnknownStatusIsNotASuccess() {
        let result = ValidationResult.fromJSON(.object(["global_status": "SOMETHING_NEW"]))
        #expect(result.status == .unknown)
        #expect(!result.isSuccess)
        // The raw string survives so telemetry and support can see what actually came back.
        #expect(result.globalStatus == "SOMETHING_NEW")
    }

    @Test func readsARedirection() {
        let result = ValidationResult.fromJSON(.object([
            "global_status": "WAITING",
            "redirection": .object([
                "url": "https://3ds.example/challenge",
                "should_submit_widget": true,
            ]),
        ]))

        #expect(result.redirection?.url == "https://3ds.example/challenge")
        #expect(result.redirection?.shouldSubmitWidget == true)
        #expect(result.redirection?.form == nil)
    }

    /// A blank url/form is the API saying "nothing here" — it must not read as a redirect target.
    @Test func blankRedirectionFieldsBecomeNil() {
        let result = ValidationResult.fromJSON(.object([
            "global_status": "SUCCESS",
            "redirection": .object(["url": "", "form": "   "]),
        ]))

        #expect(result.redirection?.url == nil)
        #expect(result.redirection?.form == nil)
    }

    @Test func noRedirectionMeansNil() {
        #expect(ValidationResult.fromJSON(.object(["global_status": "SUCCESS"])).redirection == nil)
    }

    @Test(arguments: [
        ("SUCCESS", PaymentStatus.success), ("FAILED", .failed), ("ERROR", .error),
        ("UNCERTAIN", .uncertain), ("WAITING", .waiting), ("nonsense", .unknown),
    ])
    func mapsEveryKnownStatus(_ wire: String, _ expected: PaymentStatus) {
        #expect(PaymentStatus.fromWire(wire) == expected)
    }

    @Test func statusMatchIsCaseInsensitive() {
        #expect(PaymentStatus.fromWire("success") == .success)
    }
}
