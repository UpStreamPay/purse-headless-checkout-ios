import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// Which redirects are genuine, and which are the widget talking to itself.
struct RedirectionResolverTests {

    private func response(
        results: [JSONValue] = [],
        redirection: [String: JSONValue]? = nil
    ) -> JSONValue {
        var object: [String: JSONValue] = ["global_status": "WAITING", "results": .array(results)]
        if let redirection { object["redirection"] = .object(redirection) }
        return .object(object)
    }

    private func result(
        partner: String = "purse",
        method: String = "creditcard",
        logs: [String: JSONValue]
    ) -> JSONValue {
        .object([
            "partner": .string(partner),
            "method": .string(method),
            "plugin_result": .object(["logs": .object(logs)]),
        ])
    }

    private func resolve(_ response: JSONValue, sessionReturnURL: String? = nil) -> RedirectAction? {
        RedirectionResolver.resolve(
            validateResponse: response,
            partner: "purse",
            method: "creditcard",
            sessionReturnURL: sessionReturnURL
        )
    }

    // MARK: Priority order

    /// 1. A per-item POST form beats everything else.
    @Test func perItemPostFormWinsFirst() {
        let action = resolve(response(
            results: [result(logs: [
                "redirection_json": "PaReq=abc&MD=xyz",
                "redirection_url": "https://acs.bank.example/3ds",
            ])],
            redirection: ["url": "https://elsewhere.example/ignored"]
        ))

        #expect(action == .postForm(url: "https://acs.bank.example/3ds", formDataURLEncoded: "PaReq=abc&MD=xyz"))
    }

    /// 2. A global URL alone is a GET.
    @Test func aGlobalURLIsAGet() {
        let action = resolve(response(redirection: ["url": "https://acs.bank.example/3ds"]))
        #expect(action == .get(url: "https://acs.bank.example/3ds"))
    }

    /// 2b. …unless the item also carries post params, which make it a POST to that URL.
    @Test func aGlobalURLWithPostParamsIsAPostForm() {
        let action = resolve(response(
            results: [result(logs: ["redirect_url_post_params": "a=1&b=2"])],
            redirection: ["url": "https://acs.bank.example/3ds"]
        ))
        #expect(action == .postForm(url: "https://acs.bank.example/3ds", formDataURLEncoded: "a=1&b=2"))
    }

    /// 3. Raw HTML last.
    @Test func rawFormHTMLIsPostHTML() {
        let action = resolve(response(redirection: ["form": "<form action='...'></form>"]))
        #expect(action == .postHTML(html: "<form action='...'></form>"))
    }

    @Test func noRedirectionMeansNothingToFollow() {
        #expect(resolve(response()) == nil)
    }

    // MARK: Suppression — the widget talking to itself

    /// The `purse-redirection-data` marker means the widget's own confirmation page, whose JWT
    /// decodes to the very status this same `/validate` already returned. Never a PSP redirect.
    @Test func theWidgetConfirmationRedirectIsSuppressed() {
        let url = "https://shop.example/widgets/confirmation?purse-redirection-data=eyJhbGc"
        #expect(resolve(response(redirection: ["url": .string(url)])) == nil)
    }

    /// Suppression works even with no session return URL to compare against.
    @Test func suppressionDoesNotDependOnTheSessionReturnURL() {
        let url = "https://anything.example/x?purse-redirection-data=abc"
        #expect(resolve(response(redirection: ["url": .string(url)]), sessionReturnURL: nil) == nil)
    }

    /// A target that is just the session's own return URL is not a redirect either.
    @Test func theSessionsOwnReturnURLIsSuppressed() {
        let action = resolve(
            response(redirection: ["url": "https://shop.example/return?x=1"]),
            sessionReturnURL: "https://shop.example/return"
        )
        #expect(action == nil)
    }

    /// A genuine ACS redirect survives, even when a return URL is configured.
    @Test func aGenuineRedirectSurvivesSuppression() {
        let action = resolve(
            response(redirection: ["url": "https://acs.bank.example/3ds"]),
            sessionReturnURL: "https://shop.example/return"
        )
        #expect(action == .get(url: "https://acs.bank.example/3ds"))
    }

    /// `postHTML` has no target URL, so suppression cannot apply to it.
    @Test func htmlFormsAreNeverSuppressed() {
        let action = resolve(
            response(redirection: ["form": "<form/>"]),
            sessionReturnURL: "https://shop.example/return"
        )
        #expect(action == .postHTML(html: "<form/>"))
    }

    // MARK: Per-item scoping

    /// A result belonging to a different method must not be read as this one's redirect.
    @Test func anotherMethodsResultIsIgnored() {
        let action = resolve(response(
            results: [result(partner: "paypal", method: "wallet", logs: [
                "redirection_json": "x=1",
                "redirection_url": "https://paypal.example/approve",
            ])]
        ))
        #expect(action == nil)
    }

    // MARK: Payment id

    /// The id lives **inside** the `purse-redirection-data` JWT, not in a sibling query parameter.
    private static let confirmationJWT =
        "header.eyJjbGllbnRfc2Vzc2lvbl9zdGF0dXMiOiJTVUJNSVRURUQiLCJwYXltZW50X2lkIjoicGF5XzEyMyIsImF1dGhvcml6YXRpb25fc3RhdHVzIjoiQVVUSE9SSVpFRCJ9.signature"

    private static var confirmationURL: String {
        "https://shop.example/confirmation?purse-redirection-data=\(confirmationJWT)"
    }

    @Test func readsThePaymentIdOutOfTheConfirmationJWT() {
        let id = RedirectionResolver.widgetConfirmationPaymentId(
            validateResponse: response(redirection: ["url": .string(Self.confirmationURL)])
        )
        #expect(id == "pay_123")
    }

    /// A percent-encoded JWT is the same JWT.
    @Test func readsThePaymentIdWhenTheJWTIsPercentEncoded() {
        let encoded = Self.confirmationJWT.replacingOccurrences(of: ".", with: "%2E")
        let url = "https://shop.example/confirmation?purse-redirection-data=\(encoded)"
        #expect(url.widgetConfirmationPaymentId == "pay_123")
    }

    /// A JWT with no `payment_id` in its payload yields nothing rather than guessing.
    @Test func noPaymentIdWhenTheJWTPayloadHasNone() {
        // {"client_session_status":"SUBMITTED"}
        let jwt = "header.eyJjbGllbnRfc2Vzc2lvbl9zdGF0dXMiOiJTVUJNSVRURUQifQ.signature"
        let url = "https://shop.example/confirmation?purse-redirection-data=\(jwt)"
        #expect(url.widgetConfirmationPaymentId == nil)
    }

    /// Available even when the same redirect is suppressed — it is read off the response, not by
    /// following anything.
    @Test func thePaymentIdSurvivesSuppression() {
        let body = response(redirection: ["url": .string(Self.confirmationURL)])

        #expect(resolve(body) == nil)
        #expect(RedirectionResolver.widgetConfirmationPaymentId(validateResponse: body) == "pay_123")
    }

    @Test func noPaymentIdOnAGenuineRedirect() {
        let body = response(redirection: ["url": "https://acs.bank.example/3ds"])
        #expect(RedirectionResolver.widgetConfirmationPaymentId(validateResponse: body) == nil)
    }

    // MARK: Return URL hint

    @Test func theReturnURLPrefixCanBeAttachedToAnyVariant() {
        let prefix = "https://shop.example/return"
        #expect(RedirectAction.get(url: "u").withReturnURLPrefix(prefix).returnURLPrefix == prefix)
        #expect(RedirectAction.postForm(url: "u", formDataURLEncoded: "f").withReturnURLPrefix(prefix).returnURLPrefix == prefix)
        #expect(RedirectAction.postHTML(html: "h").withReturnURLPrefix(prefix).returnURLPrefix == prefix)
    }
}

/// The `purse-redirection-data` JWT's claims. It is how a redirect return reports the payment's
/// status, and it is read unsigned — the suite exists to pin the shape, not to bless the trust.
@Suite struct WidgetRedirectionDataTests {

    private func url(_ payload: String) -> String {
        let base64 = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "https://shop.example/return?purse-redirection-data=header.\(base64).signature"
    }

    @Test func readsEveryClaimTheTokenCarries() throws {
        let data = try #require(url(
            #"{"client_session_status":"SUBMITTED","payment_id":"pay_123","authorization_status":"AUTHORIZED"}"#
        ).widgetRedirectionData)

        #expect(data.paymentId == "pay_123")
        #expect(data.authorizationStatus == "AUTHORIZED")
        #expect(data.clientSessionStatus == "SUBMITTED")
        #expect(data.isAuthorized)
    }

    @Test func aRefusalIsNotAuthorized() throws {
        let data = try #require(url(#"{"authorization_status":"REFUSED"}"#).widgetRedirectionData)
        #expect(!data.isAuthorized)
        #expect(data.paymentId == nil)
    }

    /// A token that says nothing about authorization must not read as a refusal either — the caller
    /// has to be able to tell "not authorized" from "did not say".
    @Test func anAbsentStatusIsNotAClaim() throws {
        let data = try #require(url(#"{"payment_id":"pay_9"}"#).widgetRedirectionData)
        #expect(data.authorizationStatus == nil)
        #expect(!data.isAuthorized)
    }

    @Test func aURLWithNoTokenCarriesNothing() {
        #expect("https://shop.example/return?foo=bar".widgetRedirectionData == nil)
    }
}
