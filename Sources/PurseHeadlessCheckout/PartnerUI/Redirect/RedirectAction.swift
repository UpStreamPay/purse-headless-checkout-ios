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

    /// Best-effort `payment_id` off a widget-confirmation redirect.
    var widgetConfirmationPaymentId: String? {
        guard isWidgetConfirmationRedirect,
              let components = URLComponents(string: self)
        else { return nil }
        return components.queryItems?.first { $0.name == "payment_id" }?.value?.nonBlank
    }
}
