// Web: `manageRedirection` action shapes (GET url, POST form, HTML)
// Same: same three shapes.
// Differs: carries the session return URL as a completion hint.

import Foundation

/// What a `/validate` response is asking the client to do next, resolved by
/// ``RedirectionResolver``.
public enum RedirectAction: Sendable, Equatable {
    /// Full-page GET navigation.
    case get(url: String, returnURLPrefix: String? = nil)
    /// POST navigation with form fields — needs a real web view; there is no POST-capable system browser.
    case postForm(url: String, formDataURLEncoded: String, returnURLPrefix: String? = nil)
    /// The server sent literal `<form>` HTML to inject and auto-submit.
    case postHTML(html: String, returnURLPrefix: String? = nil)

    public var returnURLPrefix: String? {
        switch self {
        case let .get(_, prefix), let .postForm(_, _, prefix), let .postHTML(_, prefix): prefix
        }
    }

    /// The URL this action navigates to, when it has one. `postHTML` carries markup, not a target.
    public var targetURL: String? {
        switch self {
        case let .get(url, _): url
        case let .postForm(url, _, _): url
        case .postHTML: nil
        }
    }

    /// Attaches a completion-hint prefix to any variant.
    public func withReturnURLPrefix(_ prefix: String?) -> RedirectAction {
        switch self {
        case let .get(url, _): .get(url: url, returnURLPrefix: prefix)
        case let .postForm(url, form, _): .postForm(url: url, formDataURLEncoded: form, returnURLPrefix: prefix)
        case let .postHTML(html, _): .postHTML(html: html, returnURLPrefix: prefix)
        }
    }
}

public extension String {
    /// Web's `purse-redirection-data` query parameter marks the widget's own confirmation-page
    /// redirect — it carries the payment's signed final result for a browser to read.
    var isWidgetConfirmationRedirect: Bool {
        contains("purse-redirection-data") || isWidgetConfirmationEndpoint
    }

    /// The Payment API's own `…/client-sessions/{id}/redirection` endpoint — the confirmation hop
    /// *before* it has bounced, so the `purse-redirection-data` marker is not on it yet.
    var isWidgetConfirmationEndpoint: Bool {
        guard let path = URLComponents(string: self)?.path else { return false }
        return path.contains("/client-sessions/") && path.hasSuffix("/redirection")
    }

    /// PayPal's own hosted approval pages — `checkoutnow` for a payment, `agreements/approve` for a
    /// vault setup. Matched on host suffix + path so it covers both `www.paypal.com` and
    /// `www.sandbox.paypal.com`.
    var isPayPalApprovalEcho: Bool {
        contains("paypal.com/checkoutnow") || contains("paypal.com/agreements/approve")
    }

    /// The claims in a widget-confirmation redirect's `purse-redirection-data` **JWT** — not
    /// sibling query parameters, which the server does not send.
    var widgetRedirectionData: WidgetRedirectionData? {
        let marker = "purse-redirection-data="
        guard let markerRange = range(of: marker) else { return nil }

        let rawValue = self[markerRange.upperBound...].prefix { $0 != "&" }
        let jwt = String(rawValue).removingPercentEncoding ?? String(rawValue)
        let segments = jwt.split(separator: ".")
        guard segments.count > 1 else { return nil }

        // base64url, and the padding a JWT omits.
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }

        return WidgetRedirectionData(
            paymentId: json["payment_id"]?.stringValue?.nonBlank,
            authorizationStatus: json["authorization_status"]?.stringValue?.nonBlank,
            clientSessionStatus: json["client_session_status"]?.stringValue?.nonBlank
        )
    }

    /// The id the orchestration API's `POST /v2/payments/{id}/captures` needs.
    var widgetConfirmationPaymentId: String? { widgetRedirectionData?.paymentId }
}

/// What a widget-confirmation redirect reports, out of its `purse-redirection-data` JWT. Android
/// confirmed the shape against a real one:
/// `{"client_session_status":"SUBMITTED","payment_id":"…","authorization_status":"AUTHORIZED"}`.
public struct WidgetRedirectionData: Sendable, Equatable {
    public let paymentId: String?
    /// `AUTHORIZED`, or whatever the API reported.
    public let authorizationStatus: String?
    /// `SUBMITTED`, and so on.
    public let clientSessionStatus: String?

    public init(paymentId: String?, authorizationStatus: String?, clientSessionStatus: String?) {
        self.paymentId = paymentId
        self.authorizationStatus = authorizationStatus
        self.clientSessionStatus = clientSessionStatus
    }

    /// What the token *claims*. Never proof on its own — nothing here is signature-checked.
    public var isAuthorized: Bool { authorizationStatus?.uppercased() == "AUTHORIZED" }
}
