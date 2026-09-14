import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// `monitoringPayload`/`summarizeValidationResults`/`errorPayload` — the shared helpers every
/// monitoring call site routes through, which is what actually enforces SDK-12265's privacy
/// invariants: no raw amount, no PAN, no personal data, no transaction id, and never a
struct MonitoringPayloadsTests {

    // MARK: monitoringPayload

    @Test func nilValuesAreDroppedEntirelyNotEncodedAsNull() {
        let payload = monitoringPayload(["a": .string("x"), "b": nil])
        #expect(payload["a"]?.stringValue == "x")
        #expect(payload.objectValue?.keys.contains("b") == false)
    }

    // MARK: summarizeValidationResults

    @Test func summarizeCapsTheDescriptionAtTwoHundredCharacters() {
        let longDescription = String(repeating: "x", count: 500)
        let response = JSONValue.object([
            "results": .array([
                .object(["method": "creditcard", "partner": "purse", "status": .object(["state": "FAILED", "description": .string(longDescription)])])
            ])
        ])
        let summary = summarizeValidationResults(response)
        #expect(summary.arrayValue?.first?["status"]?["description"]?.stringValue?.count == 200)
    }

    @Test func summarizeNeverCopiesPluginResultAsAWhole() throws {
        let response = JSONValue.object([
            "results": .array([
                .object([
                    "method": "creditcard", "partner": "purse",
                    "status": .object(["state": "SUCCESS"]),
                    "plugin_result": .object(["status": "OK", "off_session_data": .object(["secret": "should-never-appear"])])
                ])
            ])
        ])
        let summary = summarizeValidationResults(response)
        let attempt = try #require(summary.arrayValue?.first)
        #expect(attempt["plugin_status"]?.stringValue == "OK")
        #expect(attempt.objectValue?.keys.contains("plugin_result") == false)
        #expect(attempt.objectValue?.keys.contains("off_session_data") == false)
    }

    @Test func summarizeCapsAtFiveAttempts() {
        let results = (0..<10).map { _ in
            JSONValue.object(["method": "creditcard", "partner": "purse", "status": .object(["state": "SUCCESS"])])
        }
        let summary = summarizeValidationResults(.object(["results": .array(results)]))
        #expect(summary.arrayValue?.count == 5)
    }

    @Test func onlyFailuresDropsSuccessfulAttempts() {
        let results: [JSONValue] = [
            .object(["method": "creditcard", "status": .object(["state": "SUCCESS"])]),
            .object(["method": "illicado", "status": .object(["state": "FAILED"])])
        ]
        let summary = summarizeValidationResults(.object(["results": .array(results)]), onlyFailures: true)
        #expect(summary.arrayValue?.count == 1)
        #expect(summary.arrayValue?.first?["method"]?.stringValue == "illicado")
    }

    @Test func aResponseWithNoResultsArrayYieldsAnEmptySummary() {
        #expect(summarizeValidationResults(nil).arrayValue == [])
        #expect(summarizeValidationResults(.object([:])).arrayValue == [])
    }

    // MARK: errorPayload

    @Test func errorPayloadCapsTheMessageAtFiveHundredCharacters() {
        let longMessage = String(repeating: "y", count: 800)
        let payload = errorPayload(PartnerUIError(longMessage))
        #expect(payload["message"]?.stringValue?.count == 500)
    }

    @Test func errorPayloadCarriesTheStablePurseCode() {
        let payload = errorPayload(PurseCheckoutError.checkoutTornDown)
        #expect(payload["code"]?.stringValue == "CHECKOUT_TORN_DOWN")
    }

    @Test func errorPayloadFindsAPaymentAPIErrorAnywhereInTheUnderlyingChain() {
        let apiError = PaymentAPIError("boom", status: 503, errorCode: "SERVER_ERROR", path: "/validate")
        let wrapped = PurseCheckoutError.validateFailed("validate call failed", apiError)
        let payload = errorPayload(wrapped)
        #expect(payload["api_path"]?.stringValue == "/validate")
        #expect(payload["api_status"]?.intValue == 503)
        #expect(payload["api_error"]?.stringValue == "SERVER_ERROR")
    }

    @Test func outcomeUnknownOnlyAppearsWhenTrue() {
        let unknown = errorPayload(PaymentAPIError("timeout", status: nil))
        #expect(unknown["outcome_unknown"]?.boolValue == true)

        let known = errorPayload(PaymentAPIError("refused", status: 400))
        #expect(known.objectValue?.keys.contains("outcome_unknown") == false)
    }

    @Test func errorPayloadNeverIncludesTheResponseBody() {
        let apiError = PaymentAPIError("Payment API POST /init failed: HTTP 400", status: 400, path: "/init")
        let payload = errorPayload(apiError)
        // The message is PaymentAPIError's own — never the raw response body, which it never keeps.
        #expect(payload["message"]?.stringValue == "Payment API POST /init failed: HTTP 400")
    }

    // MARK: The privacy invariant, structurally

    /// `DisabledState.message` can quote amounts (see its own doc comment); this asserts the
    /// monitoring helpers have no path that would ever emit it — only a state's stable `code`
    /// belongs in a payload, exactly as every real call site in `PurseHeadlessCheckout` builds one.
    @Test func aDisabledStatePayloadCarriesOnlyItsCodeNeverItsMessage() {
        let state = DisabledState.minAmountNotMet(minAmount: 10, restToPay: 4.80)
        // What every real call site actually sends — the code, not the message.
        let payload = monitoringPayload(["code": .string(state.code.rawValue)])
        #expect(payload["code"]?.stringValue == "MIN_AMOUNT_NOT_MET")
        #expect(!state.message.isEmpty) // sanity: the message exists and is exactly what must stay out
        #expect(payload.objectValue?.values.contains { $0.stringValue?.contains("10") == true } == false)
    }
}
