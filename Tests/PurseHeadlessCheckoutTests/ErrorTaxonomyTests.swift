import Foundation
import Testing
@testable import PurseHeadlessCheckout

struct ErrorTaxonomyTests {

    /// `outcomeUnknown` means the payment may exist; reporting it as a failure double-charges a
    /// shopper who retries.
    @Test func transportFailureLeavesTheOutcomeUnknown() {
        let error = PaymentAPIError("boom", path: "/validate")
        #expect(error.outcomeUnknown)
        #expect(error.isRetryable)
    }

    @Test func anAnsweredCallHasAKnownOutcome() {
        #expect(!PaymentAPIError("boom", status: 500).outcomeUnknown)
        #expect(!PaymentAPIError("boom", status: 400).outcomeUnknown)
    }

    /// A 4xx is a definitive backend decision — retrying changes nothing.
    @Test(arguments: [400, 404, 409, 422, 429])
    func clientErrorsAreNotRetryable(_ status: Int) {
        #expect(!PaymentAPIError("boom", status: status).isRetryable)
    }

    @Test(arguments: [500, 502, 503])
    func serverErrorsAreRetryable(_ status: Int) {
        #expect(PaymentAPIError("boom", status: status).isRetryable)
    }

    @Test(arguments: ["SESSION_ALREADY_SUBMITTED_ERROR", "SESSION_EXPIRED", "NOT_FOUND"])
    func terminalSessionCodesAreRecognised(_ code: String) {
        #expect(PaymentAPIError("boom", status: 400, errorCode: code).isSessionTerminal)
    }

    @Test func otherCodesAreNotTerminal() {
        #expect(!PaymentAPIError("boom", status: 400, errorCode: "INVALID_FORM").isSessionTerminal)
        #expect(!PaymentAPIError("boom", status: 400).isSessionTerminal)
    }

    @Test func everyErrorCarriesItsDocumentationAnchor() {
        #expect(PurseErrorCode.expiredSession.documentationLink.hasSuffix("#expired_session"))
        #expect(PaymentAPIError("boom").documentationLink.hasSuffix("#api_error"))
        #expect(PurseSessionError.sessionMalformed("nope").documentationLink.hasSuffix("#session_malformed"))
    }

    /// A rename is a breaking change for a merchant handling both platforms.
    @Test func codeWireValuesArePinned() {
        #expect(PurseErrorCode.submitBlocked.rawValue == "SUBMIT_BLOCKED")
        #expect(PurseErrorCode.checkoutTornDown.rawValue == "CHECKOUT_TORN_DOWN")
        #expect(PurseErrorCode.paymentNotFulfilledOnSubmit.rawValue == "PAYMENT_NOT_FULFILLED_ON_SUBMIT")
        #expect(PurseErrorCode.secondaryMethodWrongPANFormat.rawValue == "SECONDARY_METHOD_WRONG_PAN_FORMAT")
        #expect(PurseErrorCode.partnerUIError.rawValue == "PARTNER_UI_ERROR")
    }

    /// The vocabulary is shared with web and Android, so the whole set is pinned — a size check
    /// would not notice a rename. `ENVIRONMENT_NOT_ALLOWED` is ahead of Android until SDK-12577.
    @Test func theCodeSetMatchesAndroid() {
        let android: Set<String> = [
            "EXPIRED_SESSION", "SESSION_MALFORMED", "SUBMIT_BLOCKED", "CHECKOUT_TORN_DOWN",
            "VALIDATE_FAILED", "POST_VALIDATE_FAILED", "PAYMENT_NOT_FULFILLED_ON_SUBMIT",
            "ELEMENT_NOT_FULFILLED", "UI_VALIDATION_FAILED_ERROR", "ON_BEFORE_VALIDATE_HOOK_FAILED",
            "METHOD_NOT_IMPLEMENTED", "METHOD_DISABLED", "PARTNER_UI_ERROR",
            "FAILED_TO_INIT_SECONDARY_TOKEN", "SECONDARY_METHOD_REQUIRED_CVV",
            "SECONDARY_METHOD_WRONG_PAN_FORMAT", "SECONDARY_METHOD_WRONG_CVV_FORMAT",
            "SECONDARY_TOKEN_EMPTY_BALANCE", "INVALID_TAKE_AMOUNT", "MAX_AMOUNT_REACHED",
            "USAGE_LIMIT_ERROR", "MISSING_WALLET_SESSION", "MISSING_TOKEN",
            "SET_WALLET_SESSION_FAILED", "INVALID_TOKEN_NAME", "TOKEN_NAME_EXISTS",
            "TOKEN_NOT_REGISTERABLE", "METHOD_NOT_REGISTERABLE", "FAILED_TO_DELETE_ALL_TOKENS",
            "METHOD_IS_NOT_SIMULABLE", "INVALID_LOAN_SIMULATION", "API_ERROR", "UNKNOWN_ERROR",
        ]
        #expect(Set(PurseErrorCode.allCases.map(\.rawValue)) == android.union(["ENVIRONMENT_NOT_ALLOWED"]))
    }

    /// A request that never left the device created no payment, so it must not claim
    /// `outcomeUnknown` — the caller acts on that by spending the session.
    @Test func anErrorRaisedBeforeTheRequestWasSentIsNeitherUnknownNorRetryable() {
        let neverSent = PaymentAPIError("unusable URL", path: "/validate", requestSent: false)
        #expect(!neverSent.outcomeUnknown)
        #expect(!neverSent.isRetryable)

        // The default still describes a real transport failure mid-flight.
        #expect(PaymentAPIError("connection lost", path: "/validate").outcomeUnknown)
    }

    @Test func errorDescriptionLeadsWithTheCode() {
        #expect(PaymentAPIError("could not reach host").description == "[API_ERROR] could not reach host")
    }
}
