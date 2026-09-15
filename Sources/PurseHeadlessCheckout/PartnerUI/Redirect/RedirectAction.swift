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
        contains("purse-redirection-data")
    }

    /// Best-effort `payment_id` out of the widget-confirmation redirect's `purse-redirection-data`
    /// **JWT** — not a sibling query parameter, which the server does not send.
    var widgetConfirmationPaymentId: String? {
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
        return json["payment_id"]?.stringValue?.nonBlank
    }
}
