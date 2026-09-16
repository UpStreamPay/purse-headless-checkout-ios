import Foundation
import Testing
@testable import PurseHeadlessCheckout

struct JSONValueTests {

    private func roundTrip(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// The whole reason numbers are kept as text. Money that goes through a `Double` comes back
    /// wrong, and a splitter working on wrong cents is a wrong payment.
    @Test(arguments: ["0.01", "42.50", "1000.00", "0.07", "19.99"])
    func decimalsSurviveTheRoundTripExactly(_ literal: String) throws {
        let decoded = try roundTrip("{\"amount\":\(literal)}")
        #expect(decoded["amount"]?.decimalValue == Decimal(string: literal))

        let reencoded = try JSONEncoder().encode(decoded)
        let again = try JSONDecoder().decode(JSONValue.self, from: reencoded)
        #expect(again["amount"]?.decimalValue == Decimal(string: literal))
    }

    @Test func decodesEveryJSONShape() throws {
        let decoded = try roundTrip("""
        {"s":"text","b":true,"n":7,"nul":null,"arr":[1,2],"obj":{"k":"v"}}
        """)

        #expect(decoded["s"]?.stringValue == "text")
        #expect(decoded["b"]?.boolValue == true)
        #expect(decoded["n"]?.intValue == 7)
        #expect(decoded["arr"]?.arrayValue?.count == 2)
        #expect(decoded["obj"]?["k"]?.stringValue == "v")
    }

    /// Subscripting treats an explicit null as absent — the distinction callers almost never want.
    @Test func explicitNullReadsAsAbsent() throws {
        let decoded = try roundTrip("{\"nul\":null}")
        #expect(decoded["nul"] == nil)
        #expect(decoded.objectValue?["nul"] == .null)
    }

    @Test func accessorsReturnNilForTheWrongType() throws {
        let decoded = try roundTrip("{\"s\":\"text\"}")
        #expect(decoded["s"]?.intValue == nil)
        #expect(decoded["s"]?.boolValue == nil)
        #expect(decoded["s"]?.arrayValue == nil)
    }

    @Test func missingKeysAreNil() throws {
        #expect(try roundTrip("{}")["nope"] == nil)
    }

    /// A number must not silently become a quoted string on the wire.
    @Test func numbersReencodeAsNumbers() throws {
        let encoded = try JSONEncoder().encode(JSONValue.object(["n": .number("12.34")]))
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"n\":12.34"))
    }

    @Test func anUnparseableNumberFailsLoudlyRatherThanBecomingAString() {
        #expect(throws: EncodingError.self) {
            try JSONEncoder().encode(JSONValue.object(["n": .number("not a number")]))
        }
    }
}
